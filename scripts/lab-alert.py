#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Alerts when a backup or the edge fails (issue #8): checks, state, pluggable sinks.

Subcommands (all take --config FILE, the JSON that the Ansible role backup_alert renders)
  run      Run all checks, alert on a change (ok -> failing: alert, failing -> ok: recovery, still failing:
           reminder after repeat_hours). Exit 1 while any check fails. Used by the systemd user timer.
  check    Run the checks and print them, send nothing, write no state. Exit 1 when one fails.
  test     Send a test message through every configured sink (and the fallbacks) and print what happened.
  status   Print the saved state (which check fails since when).

Maintenance marker (issue #21): lab.sh up/rebuild/down/purge write a small JSON file (maintenance_file in the config:
pid, started, command) while the VM is built or destroyed, and remove it at the end, also after an abort. While the
marker is valid, `run` stays silent: no check, no alert, no state change (a failing check keeps its old state). The
marker is ignored (alerts work as usual) when its process is gone, when it is older than maintenance_max_hours, when
it is from the future or unreadable. So a forgotten or stale marker can never hide a real outage for long.

Checks: rustfs (HTTP /health), cnpg (age of the last completed backup per cluster), k8up (age of the last
completed backup per namespace), replica (freshness of the off-host mirror, lab-replica.py status), edge
(HTTPS request to Traefik/whoami with the lab CA).

Sinks (SINKS below, one class each, add a new one by adding a class): matrix, desktop, journal, exec, file.
A sink raises SinkError when it cannot deliver. Delivery rule: every configured sink is tried; if none is
switched on or one failed, the fallback sinks are used as well. A message never contains a secret: only the
check name and a short reason. The Matrix token is read with sops at send time and never printed or logged.
Heartbeat (issue #8, decision 2026-11-06): an optional healthchecks.io-compatible ping URL
(kept in a SOPS file, never in git). After every `run` (including during maintenance), a successful
GET to the ping URL tells the external service that the control PC is alive and the last check cycle
finished. When any check fails, an optional fail URL is hit as well. When the control PC is off, no
ping goes out and the external service alerts (e.g. by e-mail). The provider is whatever answers that
URL (healthchecks.io, Better Stack heartbeat, Uptime Kuma push, …).

Exit codes: 0 = ok, 1 = a check failed (run/check) or no sink delivered (test), 2 = usage or config error.
"""
import argparse
import datetime
import hashlib
import http.client
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class ConfigError(Exception):
    pass


class SinkError(Exception):
    pass


def load_config(path):
    try:
        cfg = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise ConfigError("cannot read config %s: %s" % (path, e))
    for k in ("state_file", "sinks", "fallback_sinks"):
        if k not in cfg:
            raise ConfigError("config is missing: %s" % k)
    cfg.setdefault("repeat_hours", 24)
    cfg.setdefault("http_timeout", 8)
    cfg.setdefault("kubectl_bin", "kubectl")
    cfg.setdefault("kubectl_timeout", 30)
    cfg.setdefault("kubeconfig", "")
    cfg.setdefault("cnpg", {"clusters": [], "max_age_hours": 30})
    cfg.setdefault("k8up", {"namespaces": [], "max_age_hours": 30})
    cfg.setdefault("rustfs_url", "")
    cfg.setdefault("replica", {"enabled": False})
    cfg.setdefault("edge", {"enabled": False})
    cfg.setdefault("matrix", {"enabled": False})
    cfg.setdefault("desktop", {"bin": "notify-send"})
    cfg.setdefault("exec_argv", [])
    cfg.setdefault("file_path", "")
    cfg.setdefault("now", None)
    cfg.setdefault("maintenance_file", "")
    cfg.setdefault("maintenance_max_hours", 3)
    cfg.setdefault("heartbeat", {"enabled": False})
    for name in list(cfg["sinks"]) + list(cfg["fallback_sinks"]):
        if name not in SINKS:
            raise ConfigError("unknown sink '%s' (known: %s)" % (name, ", ".join(sorted(SINKS))))
    return cfg


def now(cfg):
    return float(cfg["now"]) if cfg.get("now") else time.time()


def run(argv, timeout, input_text=None):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, input=input_text)
    except FileNotFoundError:
        return 127, "", "%s: command not found" % argv[0]
    except subprocess.TimeoutExpired:
        return 124, "", "%s: timeout after %ss" % (argv[0], timeout)
    return p.returncode, p.stdout, p.stderr


# ---------------------------------------------------------------- sinks
class Sink:
    name = ""

    def __init__(self, cfg):
        self.cfg = cfg

    def enabled(self):
        return True

    def send(self, subject, body, level):
        raise NotImplementedError


class JournalSink(Sink):
    """Writes to the journal through logger; without logger to stderr (a systemd unit's stderr is the journal)."""
    name = "journal"

    def send(self, subject, body, level):
        prio = {"critical": "user.crit", "warning": "user.warning"}.get(level, "user.info")
        rc, out, err = run(["logger", "-t", "k8s-lab-alert", "-p", prio, "%s: %s" % (subject, body)], 10)
        if rc == 127:
            print("k8s-lab-alert %s: %s: %s" % (level, subject, body), file=sys.stderr)
        elif rc != 0:
            raise SinkError("logger exit %d" % rc)


class DesktopSink(Sink):
    """notify-send on the owner's PC. Needs the session bus; the user manager has it for the timer."""
    name = "desktop"

    def send(self, subject, body, level):
        urgency = {"critical": "critical", "warning": "normal"}.get(level, "low")
        rc, out, err = run([self.cfg["desktop"]["bin"], "-a", "k8s-lab", "-u", urgency, subject, body], 15)
        if rc == 127:
            raise SinkError("%s is not installed (sudo apt install libnotify-bin)" % self.cfg["desktop"]["bin"])
        if rc != 0:
            raise SinkError("notify-send exit %d (no graphical session?)" % rc)


class FileSink(Sink):
    """Appends one JSON line per alert to a file. Used by tests and as a simple audit log."""
    name = "file"

    def enabled(self):
        return bool(self.cfg["file_path"])

    def send(self, subject, body, level):
        try:
            with open(self.cfg["file_path"], "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"subject": subject, "body": body, "level": level}) + "\n")
        except OSError as e:
            raise SinkError("cannot write %s: %s" % (self.cfg["file_path"], e))


class ExecSink(Sink):
    """Runs a command; the message is on stdin, subject and level are in K8S_LAB_ALERT_SUBJECT/LEVEL."""
    name = "exec"

    def enabled(self):
        return bool(self.cfg["exec_argv"])

    def send(self, subject, body, level):
        env = dict(os.environ, K8S_LAB_ALERT_SUBJECT=subject, K8S_LAB_ALERT_LEVEL=level)
        try:
            p = subprocess.run(self.cfg["exec_argv"], input="%s\n%s\n" % (subject, body), capture_output=True, text=True,
                               timeout=30, env=env)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise SinkError("exec sink failed: %s" % e)
        if p.returncode != 0:
            raise SinkError("exec sink exit %d" % p.returncode)


class MatrixSink(Sink):
    """Matrix client-server API: PUT /rooms/{room}/send/m.room.message/{txn}. One bot user, one room.

    Synapse is reachable only through the VPN. Switched off by default (matrix.enabled false). The access token
    comes from a SOPS file (token_file, key token_key) and is decrypted with sops at send time.
    """
    name = "matrix"

    def enabled(self):
        return bool(self.cfg["matrix"].get("enabled"))

    def token(self):
        m = self.cfg["matrix"]
        env = dict(os.environ)
        if m.get("age_key_file"):
            env["SOPS_AGE_KEY_FILE"] = m["age_key_file"]
        try:
            p = subprocess.run([m.get("sops_bin", "sops"), "decrypt", "--extract", '["%s"]' % m.get("token_key", "token"),
                                m["token_file"]], capture_output=True, text=True, timeout=30, env=env)
        except FileNotFoundError:
            raise SinkError("sops is not installed")
        except subprocess.TimeoutExpired:
            raise SinkError("sops timeout")
        if p.returncode != 0 or not p.stdout.strip():
            raise SinkError("token file %s cannot be decrypted (exit %d)" % (m.get("token_file"), p.returncode))
        return p.stdout.strip()

    def send(self, subject, body, level):
        m = self.cfg["matrix"]
        for k in ("homeserver", "room_id", "token_file"):
            if not m.get(k):
                raise SinkError("matrix.%s is not set" % k)
        token = self.token()
        txn = hashlib.sha256(("%s|%s|%s" % (subject, body, now(self.cfg))).encode()).hexdigest()[:24]
        url = "%s/_matrix/client/v3/rooms/%s/send/m.room.message/%s" % (
            m["homeserver"].rstrip("/"), urllib.parse.quote(m["room_id"], safe=""), txn)
        text = "%s\n%s" % (subject, body)
        req = urllib.request.Request(url, method="PUT", data=json.dumps({"msgtype": "m.text", "body": text}).encode(),
                                     headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.cfg["http_timeout"] + 7) as r:
                if r.status != 200:
                    raise SinkError("homeserver answered %d" % r.status)
        except urllib.error.HTTPError as e:
            raise SinkError("homeserver answered %d" % e.code)
        except (urllib.error.URLError, OSError) as e:
            raise SinkError("homeserver not reachable (VPN up?): %s" % getattr(e, "reason", e))


SINKS = {c.name: c for c in (JournalSink, DesktopSink, FileSink, ExecSink, MatrixSink)}


def deliver(cfg, subject, body, level):
    """Returns a list of (sink, 'sent'|'skipped'|'failed: reason'). Fallback when nothing was sent or one failed."""
    results, sent, failed = [], 0, 0

    def attempt(name):
        nonlocal sent, failed
        sink = SINKS[name](cfg)
        if not sink.enabled():
            results.append((name, "skipped (not switched on)"))
            return
        try:
            sink.send(subject, body, level)
            results.append((name, "sent"))
            sent += 1
        except SinkError as e:
            results.append((name, "failed: %s" % e))
            failed += 1

    for name in cfg["sinks"]:
        attempt(name)
    if sent == 0 or failed:
        done = set(n for n, _ in results)
        for name in cfg["fallback_sinks"]:
            if name in done:
                continue
            attempt(name)
    return results


# ---------------------------------------------------------------- checks
def parse_time(text):
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def kubectl_json(cfg, args):
    argv = [cfg["kubectl_bin"]]
    if cfg["kubeconfig"]:
        argv += ["--kubeconfig", cfg["kubeconfig"]]
    argv += args + ["-o", "json"]
    rc, out, err = run(argv, cfg["kubectl_timeout"])
    if rc != 0:
        return None, "kubectl failed (exit %d: %s), is the cluster up?" % (rc, (err.strip().splitlines() or ["no output"])[-1][:120])
    try:
        return json.loads(out), ""
    except ValueError:
        return None, "kubectl returned no JSON"


def age_text(seconds):
    return "%.1f h" % (seconds / 3600.0)


def check_rustfs(cfg):
    url = cfg["rustfs_url"]
    if not url:
        return True, "not configured"
    try:
        with urllib.request.urlopen(url, timeout=cfg["http_timeout"]) as r:
            return (r.status == 200), "HTTP %d" % r.status
    except urllib.error.HTTPError as e:
        return False, "HTTP %d from rustfs" % e.code
    except (urllib.error.URLError, OSError) as e:
        return False, "rustfs not reachable (%s)" % getattr(e, "reason", e)


def check_cnpg(cfg):
    clusters = cfg["cnpg"]["clusters"]
    if not clusters:
        return True, "no cluster configured"
    data, why = kubectl_json(cfg, ["get", "backups.postgresql.cnpg.io", "-A"])
    if data is None:
        return False, why
    limit = float(cfg["cnpg"]["max_age_hours"]) * 3600
    bad = []
    for c in clusters:
        times = [parse_time(b.get("status", {}).get("stoppedAt")) for b in data.get("items", [])
                 if b.get("metadata", {}).get("namespace") == c["namespace"]
                 and (b.get("spec", {}).get("cluster") or {}).get("name") == c["name"]
                 and b.get("status", {}).get("phase") == "completed"]
        times = [t for t in times if t]
        if not times:
            bad.append("%s/%s: no completed backup" % (c["namespace"], c["name"]))
            continue
        age = now(cfg) - max(times)
        if age > limit:
            bad.append("%s/%s: last backup %s ago (limit %s)" % (c["namespace"], c["name"], age_text(age), age_text(limit)))
    return (not bad), ("; ".join(bad) if bad else "all %d clusters have a recent backup" % len(clusters))


def k8up_done_time(b):
    """Time of a successful K8up Backup: the Completed condition (True, Succeeded), else status.finished."""
    st = b.get("status", {})
    for c in st.get("conditions", []):
        if c.get("type") == "Completed" and c.get("status") == "True" and c.get("reason") == "Succeeded":
            return parse_time(c.get("lastTransitionTime"))
    return None


def check_k8up(cfg):
    spaces = cfg["k8up"]["namespaces"]
    if not spaces:
        return True, "no namespace configured"
    data, why = kubectl_json(cfg, ["get", "backups.k8up.io", "-A"])
    if data is None:
        return False, why
    limit = float(cfg["k8up"]["max_age_hours"]) * 3600
    bad = []
    for ns in spaces:
        times = [k8up_done_time(b) for b in data.get("items", []) if b.get("metadata", {}).get("namespace") == ns]
        times = [t for t in times if t]
        if not times:
            bad.append("%s: no successful K8up backup" % ns)
            continue
        age = now(cfg) - max(times)
        if age > limit:
            bad.append("%s: last K8up backup %s ago (limit %s)" % (ns, age_text(age), age_text(limit)))
    return (not bad), ("; ".join(bad) if bad else "all %d namespaces have a recent backup" % len(spaces))


def check_replica(cfg):
    r = cfg["replica"]
    if not r.get("enabled"):
        return True, "replica not switched on"
    rc, out, err = run(r["argv"], int(r.get("timeout", 300)))
    try:
        res = json.loads(out)
        return bool(res["ok"]), res.get("detail", "")
    except (ValueError, KeyError, TypeError):
        return False, "replica status unreadable (exit %d: %s)" % (rc, (err.strip().splitlines() or ["no output"])[-1][:120])


def check_edge(cfg):
    e = cfg["edge"]
    if not e.get("enabled"):
        return True, "edge check not switched on"
    try:
        ctx = ssl.create_default_context(cafile=e["ca_file"] or None)
        with socket.create_connection((e["ip"], int(e["port"])), timeout=cfg["http_timeout"]) as sock:
            with ctx.wrap_socket(sock, server_hostname=e["host"]) as s:
                s.sendall(("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" % e["host"]).encode())
                resp = http.client.HTTPResponse(s)
                resp.begin()
                body = resp.read(4096).decode("utf-8", "replace")
    except ssl.SSLError as ex:
        return False, "TLS problem at the edge (%s)" % (getattr(ex, "reason", None) or ex)
    except (OSError, http.client.HTTPException) as ex:
        return False, "edge not reachable at %s:%s (%s)" % (e["ip"], e["port"], ex)
    if resp.status != 200:
        return False, "edge answered HTTP %d" % resp.status
    if e.get("expect") and e["expect"] not in body:
        return False, "edge answered 200 but not with %s" % e["expect"]
    return True, "HTTPS 200 from %s" % e["host"]



# ---------------------------------------------------------------- heartbeat (external, healthchecks.io-compatible)
def sops_extract(cfg_section, file_key, value_key, label):
    """Decrypt one YAML key from a SOPS file. Never print the value."""
    path = cfg_section.get(file_key) or ""
    key = cfg_section.get(value_key) or ""
    if not path or not key:
        raise SinkError("%s: %s/%s not set" % (label, file_key, value_key))
    env = dict(os.environ)
    if cfg_section.get("age_key_file"):
        env["SOPS_AGE_KEY_FILE"] = cfg_section["age_key_file"]
    try:
        p = subprocess.run(
            [cfg_section.get("sops_bin", "sops"), "decrypt", "--extract", '["%s"]' % key, path],
            capture_output=True, text=True, timeout=30, env=env,
        )
    except FileNotFoundError:
        raise SinkError("sops is not installed")
    except subprocess.TimeoutExpired:
        raise SinkError("sops timeout")
    if p.returncode != 0 or not p.stdout.strip():
        raise SinkError("%s file %s cannot be decrypted (exit %d)" % (label, path, p.returncode))
    return p.stdout.strip()


def http_ping(url, timeout):
    """GET a URL (healthchecks.io-compatible). Returns None on success, error text otherwise.
    Never includes the URL in the returned error (it may embed a secret UUID)."""
    if not url or not (url.startswith("https://") or url.startswith("http://")):
        return "heartbeat URL is missing or not http(s)"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if 200 <= r.status < 300:
                return None
            return "heartbeat answered %d" % r.status
    except urllib.error.HTTPError as e:
        return "heartbeat answered %d" % e.code
    except (urllib.error.URLError, OSError, ValueError) as e:
        return "heartbeat not reachable: %s" % getattr(e, "reason", e)


def heartbeat_urls(cfg):
    """Return (ping_url, fail_url_or_empty). fail_url may be empty when the key is absent."""
    hb = cfg.get("heartbeat") or {}
    if not hb.get("enabled"):
        return "", ""
    ping = sops_extract(hb, "url_file", "ping_url_key", "heartbeat")
    fail = ""
    fail_key = hb.get("fail_url_key") or ""
    if fail_key:
        try:
            fail = sops_extract(hb, "url_file", "fail_url_key", "heartbeat-fail")
        except SinkError:
            fail = ""
    return ping, fail


def heartbeat_notify(cfg, all_ok):
    """Ping the external heartbeat. Always try the success URL after a run cycle.
    On failure also hit the optional fail URL. Prints a one-line status, never the URL."""
    hb = cfg.get("heartbeat") or {}
    if not hb.get("enabled"):
        return "skipped"
    try:
        ping, fail = heartbeat_urls(cfg)
    except SinkError as e:
        print("HEARTBEAT fail: %s" % e)
        return "failed"
    err = http_ping(ping, cfg["http_timeout"])
    if err:
        print("HEARTBEAT fail: %s" % err)
        return "failed"
    if not all_ok and fail:
        ferr = http_ping(fail, cfg["http_timeout"])
        if ferr:
            print("HEARTBEAT fail-url: %s" % ferr)
            return "ping-ok-fail-url-failed"
        print("HEARTBEAT ok (ping + fail)")
        return "ping-ok-fail-sent"
    print("HEARTBEAT ok")
    return "ok"


CHECKS = [("rustfs", check_rustfs), ("cnpg", check_cnpg), ("k8up", check_k8up), ("replica", check_replica), ("edge", check_edge)]


def run_checks(cfg, only=None):
    out = []
    for name, fn in CHECKS:
        if only and name not in only:
            continue
        try:
            ok, detail = fn(cfg)
        except Exception as e:  # a broken check must alert, never crash the run
            ok, detail = False, "check crashed: %s" % type(e).__name__
        out.append({"name": name, "ok": bool(ok), "detail": detail})
    return out


# ---------------------------------------------------------------- maintenance marker
def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, belongs to someone else
    except (OSError, ValueError, OverflowError):
        return False
    return True


def maintenance(cfg):
    """Returns (active, text). Fails open: anything doubtful means alerts stay switched on."""
    path = cfg["maintenance_file"]
    if not path or not os.path.exists(path):
        return False, ""
    try:
        m = json.load(open(path, encoding="utf-8"))
        started = float(m["started"])
    except (OSError, ValueError, KeyError, TypeError):
        return False, "marker %s is unreadable, ignored" % path
    limit = float(cfg["maintenance_max_hours"]) * 3600
    age = now(cfg) - started
    what = "lab.sh %s (pid %s)" % (m.get("command", "?"), m.get("pid", "?"))
    if age < 0 or age > limit:
        return False, "marker of %s is %s old (limit %s), ignored" % (what, age_text(abs(age)), age_text(limit))
    if m.get("pid") and not pid_alive(m["pid"]):
        return False, "marker of %s: process is gone, ignored" % what
    return True, "%s since %s" % (what, fmt(started))


# ---------------------------------------------------------------- state and alerts
def load_state(cfg):
    try:
        return json.load(open(cfg["state_file"], encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_state(cfg, state):
    d = os.path.dirname(cfg["state_file"])
    os.makedirs(d, exist_ok=True)
    tmp = cfg["state_file"] + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=1, sort_keys=True)
    os.replace(tmp, cfg["state_file"])


def plan(cfg, results, state):
    """Returns (messages, new_state). A message is (level, subject, body)."""
    t = now(cfg)
    repeat = float(cfg["repeat_hours"]) * 3600
    msgs, new = [], {}
    for r in results:
        old = state.get(r["name"], {"ok": True})
        if r["ok"]:
            if not old.get("ok", True):
                msgs.append(("info", "k8s-lab OK again: %s" % r["name"], "%s (was failing since %s)" % (r["detail"], fmt(old.get("since")))))
            new[r["name"]] = {"ok": True}
            continue
        if old.get("ok", True):
            msgs.append(("critical", "k8s-lab ALARM: %s" % r["name"], r["detail"]))
            new[r["name"]] = {"ok": False, "since": t, "last_alert": t}
        elif t - float(old.get("last_alert", 0)) >= repeat:
            msgs.append(("warning", "k8s-lab still failing: %s" % r["name"], "%s (since %s)" % (r["detail"], fmt(old.get("since")))))
            new[r["name"]] = dict(old, last_alert=t)
        else:
            new[r["name"]] = old
    return msgs, new


def fmt(ts):
    if not ts:
        return "unknown"
    return datetime.datetime.fromtimestamp(float(ts)).strftime("%Y-%m-%d %H:%M")


def cmd_run(cfg):
    active, why = maintenance(cfg)
    if active:
        print("MAINTENANCE: %s. Checks and alerts are paused, state unchanged." % why)
        # Still ping the external heartbeat so an intentional rebuild does not look like an outage.
        heartbeat_notify(cfg, True)
        return 0
    if why:
        print("NOTE: %s" % why)
    results = run_checks(cfg)
    state = load_state(cfg)
    msgs, new = plan(cfg, results, state)
    for r in results:
        print("%s %s: %s" % ("OK  " if r["ok"] else "FAIL", r["name"], r["detail"]))
    for level, subject, body in msgs:
        res = deliver(cfg, subject, body, level)
        print("ALERT %s -> %s" % (subject, ", ".join("%s %s" % x for x in res)))
        if not any(s == "sent" for _, s in res):
            # Nothing delivered: keep the old state so the next run tries again (no silent loss).
            name = subject.split(": ", 1)[1]
            if name in state:
                new[name] = state[name]
            else:
                new.pop(name, None)
    save_state(cfg, new)
    all_ok = all(r["ok"] for r in results)
    heartbeat_notify(cfg, all_ok)
    return 0 if all_ok else 1


def cmd_check(cfg, only):
    results = run_checks(cfg, only)
    for r in results:
        print("%s %s: %s" % ("OK  " if r["ok"] else "FAIL", r["name"], r["detail"]))
    return 0 if all(r["ok"] for r in results) else 1


def cmd_test(cfg):
    res = deliver(cfg, "k8s-lab test alert", "This is a test from lab-alert.py. No action needed.", "info")
    for name, s in res:
        print("%-8s %s" % (name, s))
    sinks_ok = any(s == "sent" for _, s in res)
    hb = heartbeat_notify(cfg, True)
    # Heartbeat off ("skipped") is fine for test; when enabled, ping must succeed.
    hb_ok = hb in ("skipped", "ok", "ping-ok-fail-sent")
    return 0 if sinks_ok and hb_ok else 1


def cmd_heartbeat(cfg):
    """Ping the external heartbeat once (manual check that the URL and SOPS file work)."""
    hb = cfg.get("heartbeat") or {}
    if not hb.get("enabled"):
        print("heartbeat is disabled (backup_alert_heartbeat_enabled)")
        return 1
    status = heartbeat_notify(cfg, True)
    return 0 if status in ("ok", "ping-ok-fail-sent") else 1


def cmd_status(cfg):
    active, why = maintenance(cfg)
    if why:
        print("maintenance: %s%s" % ("ACTIVE, " if active else "", why))
    state = load_state(cfg)
    if not state:
        print("no state yet (no run so far)")
    for name in sorted(state):
        s = state[name]
        print("%-8s %s" % (name, "ok" if s.get("ok", True) else "FAILING since %s" % fmt(s.get("since"))))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["run", "check", "test", "status", "heartbeat"])
    ap.add_argument("--config", required=True)
    ap.add_argument("--only", action="append", help="check: only this check (rustfs, cnpg, k8up, replica, edge)")
    a = ap.parse_args(argv)
    try:
        cfg = load_config(a.config)
    except ConfigError as e:
        print("CONFIG ERROR: %s" % e, file=sys.stderr)
        return 2
    return {"run": lambda: cmd_run(cfg), "check": lambda: cmd_check(cfg, a.only), "test": lambda: cmd_test(cfg),
            "status": lambda: cmd_status(cfg), "heartbeat": lambda: cmd_heartbeat(cfg)}[a.cmd]()


if __name__ == "__main__":
    sys.exit(main())
