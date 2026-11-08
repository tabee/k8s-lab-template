#!/usr/bin/env python3
"""Stage 8a: S3 helper for rustfs (Python standard library only).

Reads keys itself from env files or the environment, never prints keys,
not even the access key ID (messages only name file, bucket, policy).
Output: one JSON line {"ok", "changed", "actions", "message"}.
Exit 0 = ok, 1 = error, 2 = wrong usage.

  rustfs-s3.py health    --endpoint URL [--version V]
  rustfs-s3.py ensure    --endpoint URL --root-env FILE --user-env FILE
                         --bucket B --policy NAME --policy-json JSON
                         [--versioning on|off] [--noncurrent-days N] [--check]
  rustfs-s3.py roundtrip --endpoint URL --bucket B [--deny B ...] [--prefix P]
                         (keys: --user-env FILE or environment
                          S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY)
  rustfs-s3.py purge     --endpoint URL --root-env FILE --bucket B --prefix P
  rustfs-s3.py buckets   --endpoint URL --root-env FILE
                         (actions = all bucket names)
  rustfs-s3.py drop-bucket --endpoint URL --root-env FILE --bucket B [--check]
                         (delete the bucket including all versions; --check only
                          counts; if the bucket is missing: changed=false)
"""
import argparse
import base64
import datetime
import hashlib
import hmac
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REGION = "us-east-1"
LC_ID = "k8s-lab-old-versions"


class S3Error(Exception):
    pass


def read_env(fpath, key_name):
    values = {}
    try:
        with open(os.path.expanduser(fpath), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if k.startswith("export "):
                    k = k[7:].strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1]
                values[k] = v
    except FileNotFoundError:
        raise S3Error("File missing: %s" % fpath)
    missing = [k for k in key_name if not values.get(k)]
    if missing:
        raise S3Error("%s: key missing or empty: %s" % (fpath, ", ".join(missing)))
    return [values[k] for k in key_name]


class S3:
    # Seconds that req() retries on 503 ("waiting for iam" after startup) or
    # a missing connection. main() sets the value from --wait.
    wait = 90

    def __init__(self, endpoint, ak, sk):
        self.ep = endpoint.rstrip("/")
        self.ak = ak
        self.sk = sk

    def req(self, method, path, query=None, body=b"", headers=None, service="s3"):
        end_t = time.monotonic() + self.wait
        while True:
            try:
                status, answer = self._req(method, path, query, body, headers, service)
            except S3Error:
                if time.monotonic() >= end_t:
                    raise
            else:
                if status != 503 or time.monotonic() >= end_t:
                    return status, answer
            time.sleep(2)

    def _req(self, method, path, query, body, headers, service):
        u = urllib.parse.urlsplit(self.ep)
        q = sorted((query or {}).items())
        cq = "&".join(
            "%s=%s" % (urllib.parse.quote(k, safe="-_.~"), urllib.parse.quote(str(v), safe="-_.~"))
            for k, v in q)
        t = datetime.datetime.now(datetime.timezone.utc)
        amz = t.strftime("%Y%m%dT%H%M%SZ")
        tag = t.strftime("%Y%m%d")
        ph = hashlib.sha256(body).hexdigest()
        h = {"host": u.netloc, "x-amz-date": amz, "x-amz-content-sha256": ph}
        h.update({k.lower(): v for k, v in (headers or {}).items()})
        sh = ";".join(sorted(h))
        ch = "".join("%s:%s\n" % (k, h[k].strip()) for k in sorted(h))
        cp = urllib.parse.quote(path, safe="/-_.~")
        creq = "\n".join([method, cp, cq, ch, sh, ph])
        scope = "%s/%s/%s/aws4_request" % (tag, REGION, service)
        sts = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(creq.encode()).hexdigest()])

        def s(k, m):
            return hmac.new(k, m.encode(), hashlib.sha256).digest()
        k = s(s(s(s(("AWS4" + self.sk).encode(), tag), REGION), service), "aws4_request")
        sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
        h["authorization"] = "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" % (
            self.ak, scope, sh, sig)
        url = self.ep + cp + ("?" + cq if cq else "")
        r = urllib.request.Request(url, data=body if method in ("PUT", "POST") else None,
                                   method=method, headers=h)
        try:
            with urllib.request.urlopen(r, timeout=20) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except (urllib.error.URLError, OSError) as e:
            raise S3Error("%s not reachable: %s" % (self.ep, getattr(e, "reason", e)))

    def admin(self, method, op, query=None, body=None):
        b = json.dumps(body).encode() if body is not None else b""
        return self.req(method, "/rustfs/admin/v3/" + op, query, b)


def code(body):
    m = re.search(rb"<Code>([^<]+)</Code>", body or b"")
    if m:
        return m.group(1).decode()
    try:
        return json.loads(body.decode()).get("Code", "")
    except Exception:
        return ""


def check(status, body, ok, was):
    if status not in ok:
        raise S3Error("%s: HTTP %s %s" % (was, status, code(body)))


def norm_policy(p):
    if isinstance(p, str):
        p = json.loads(p)
    st = []
    for s in p.get("Statement", []):
        a = s.get("Action", [])
        r = s.get("Resource", [])
        st.append(json.dumps({
            "Effect": s.get("Effect"),
            "Action": sorted([a] if isinstance(a, str) else a),
            "Resource": sorted([r] if isinstance(r, str) else r),
        }, sort_keys=True))
    return sorted(st)


def md5h(b):
    return base64.b64encode(hashlib.md5(b).digest()).decode()  # nosec - S3 requires Content-MD5


def cmd_health(a):
    u = a.endpoint.rstrip("/") + "/health"
    try:
        with urllib.request.urlopen(u, timeout=10) as r:
            d = json.loads(r.read().decode() or "{}")
    except Exception as e:
        raise S3Error("%s: %s" % (u, e))
    if d.get("status") != "ok":
        raise S3Error("%s: status=%s" % (u, d.get("status")))
    if a.version and d.get("version") != a.version:
        raise S3Error("%s: version %s, expected %s" % (u, d.get("version"), a.version))
    return False, [], "healthy, version %s" % d.get("version")


def cmd_ensure(a):
    ak, sk = read_env(a.root_env, ["RUSTFS_ACCESS_KEY", "RUSTFS_SECRET_KEY"])
    root = S3(a.endpoint, ak, sk)
    acts = []
    try:
        expected_policy = json.loads(a.policy_json)
    except ValueError as e:
        raise S3Error("--policy-json is not JSON: %s" % e)
    try:
        uk, us = read_env(a.user_env, ["ACCESS_KEY_ID", "ACCESS_SECRET_KEY"])
    except S3Error:
        if not a.check:
            raise
        uk, us = None, None
        acts.append("user key would be created (%s)" % a.user_env)
    bpath = "/" + a.bucket

    # 1. Bucket
    st, b = root.req("HEAD", bpath)
    new_bucket = st == 404
    if new_bucket:
        acts.append("Create bucket %s" % a.bucket)
        if not a.check:
            st, b = root.req("PUT", bpath)
            check(st, b, (200,), "Create bucket")
    else:
        check(st, b, (200,), "Check bucket")

    # 2. Versioning
    if not new_bucket or not a.check:
        st, b = root.req("GET", bpath, {"versioning": ""})
        check(st, b, (200,), "Read versioning")
        actual = re.search(rb"<Status>([^<]+)</Status>", b)
        actual = actual.group(1).decode() if actual else "Off"
    else:
        actual = "Off"
    expected = "Enabled" if a.versioning == "on" else ("Suspended" if actual != "Off" else "Off")
    if actual != expected:
        acts.append("Versioning %s -> %s" % (actual, expected))
        if not a.check:
            x = ('<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                 "<Status>%s</Status></VersioningConfiguration>" % expected).encode()
            st, b = root.req("PUT", bpath, {"versioning": ""}, x)
            check(st, b, (200,), "Set versioning")

    # 3. Lifecycle: clean up old versions and orphaned delete markers
    if a.versioning == "on" and a.noncurrent_days > 0:
        actual_days = None
        if not new_bucket or not a.check:
            st, b = root.req("GET", bpath, {"lifecycle": ""})
            if st == 200:
                m = re.search(rb"<NoncurrentDays>(\d+)</NoncurrentDays>", b)
                if m and (b"<ID>%s</ID>" % LC_ID.encode()) in b and b"ExpiredObjectDeleteMarker>true" in b:
                    actual_days = int(m.group(1))
            elif code(b) != "NoSuchLifecycleConfiguration":
                check(st, b, (200,), "Read lifecycle")
        if actual_days != a.noncurrent_days:
            acts.append("Lifecycle: delete old versions after %s days" % a.noncurrent_days)
            if not a.check:
                x = ('<LifecycleConfiguration><Rule><ID>%s</ID><Status>Enabled</Status>'
                     "<Filter><Prefix></Prefix></Filter>"
                     "<Expiration><ExpiredObjectDeleteMarker>true</ExpiredObjectDeleteMarker></Expiration>"
                     "<NoncurrentVersionExpiration><NoncurrentDays>%d</NoncurrentDays>"
                     "</NoncurrentVersionExpiration></Rule></LifecycleConfiguration>"
                     % (LC_ID, a.noncurrent_days)).encode()
                st, b = root.req("PUT", bpath, {"lifecycle": ""}, x, {"Content-MD5": md5h(x)})
                check(st, b, (200,), "Set lifecycle")

    # 4. Policy (this bucket only)
    st, b = root.admin("GET", "info-canned-policy", {"name": a.policy})
    if st == 200:
        d = json.loads(b.decode())
        actual_p = d.get("Policy", d.get("policy", d))
        same = norm_policy(actual_p) == norm_policy(expected_policy)
    elif st == 404:
        same = False
    else:
        check(st, b, (200, 404), "Read policy")
    if not same:
        acts.append("Write policy %s" % a.policy)
        if not a.check:
            st, b = root.admin("PUT", "add-canned-policy", {"name": a.policy}, expected_policy)
            check(st, b, (200,), "Write policy")

    # 5. User. Output only names the file, never the access key ID.
    if uk is not None:
        unam = os.path.basename(a.user_env)
        st, b = root.admin("GET", "user-info", {"accessKey": uk})
        if st == 404:
            info = None
        else:
            check(st, b, (200,), "Read user")
            info = json.loads(b.decode())
        new_user = info is None or info.get("status") != "enabled"
        if not new_user and not a.check and not new_bucket:
            # Does the secret in the file still match? (without showing it)
            st, b = S3(a.endpoint, uk, us).req("GET", bpath, {"list-type": "2", "max-keys": "1"})
            if st != 200 and code(b) in ("SignatureDoesNotMatch", "InvalidAccessKeyId"):
                new_user = True
        if new_user:
            acts.append("User from %s %s" % (unam, "create" if info is None else "set key/status"))
            if not a.check:
                st, b = root.admin("PUT", "add-user", {"accessKey": uk},
                                   {"secretKey": us, "status": "enabled"})
                check(st, b, (200,), "Create user")
        has = (info or {}).get("policyName", "")
        if has != a.policy:
            acts.append("Bind policy %s to user from %s (was: %s)" % (a.policy, unam, has or "none"))
            if not a.check:
                st, b = root.admin("PUT", "set-user-or-group-policy",
                                   {"policyName": a.policy, "userOrGroup": uk, "isGroup": "false"})
                check(st, b, (200,), "Bind policy")
        if not a.check:
            st, b = S3(a.endpoint, uk, us).req("GET", bpath, {"list-type": "2", "max-keys": "1"})
            check(st, b, (200,), "Test with user key")
    return bool(acts), acts, ("Check mode: " if a.check else "") + ("%d change(s)" % len(acts) if acts else "all up to date")


def user_s3(a):
    if a.user_env:
        ak, sk = read_env(a.user_env, ["ACCESS_KEY_ID", "ACCESS_SECRET_KEY"])
    else:
        ak, sk = os.environ.get("S3_ACCESS_KEY_ID"), os.environ.get("S3_SECRET_ACCESS_KEY")
        if not ak or not sk:
            raise S3Error("S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY missing")
    return S3(a.endpoint, ak, sk)


def cmd_roundtrip(a):
    s3 = user_s3(a)
    acts = []
    key = "%s%s-%d.txt" % (a.prefix, os.uname()[1], int(time.time()))
    content = os.urandom(32).hex().encode()
    st, b = s3.req("PUT", "/%s/%s" % (a.bucket, key), body=content)
    check(st, b, (200,), "PUT %s" % key)
    st, b = s3.req("GET", "/%s/%s" % (a.bucket, key))
    check(st, b, (200,), "GET %s" % key)
    if b != content:
        raise S3Error("GET %s: content differs from what was written" % key)
    st, b = s3.req("GET", "/" + a.bucket, {"list-type": "2", "prefix": a.prefix})
    check(st, b, (200,), "LIST %s" % a.bucket)
    if key.encode() not in b:
        raise S3Error("LIST %s: %s is missing" % (a.bucket, key))
    st, b = s3.req("DELETE", "/%s/%s" % (a.bucket, key))
    check(st, b, (204, 200), "DELETE %s" % key)
    acts.append("PUT/GET/LIST/DELETE %s/%s ok" % (a.bucket, key))
    st, b = s3.req("GET", "/")
    check(st, b, (200,), "ListBuckets")
    others = sorted(set(re.findall(rb"<Name>([^<]+)</Name>", b)) - {a.bucket.encode()})
    if others:
        raise S3Error("key sees foreign buckets: %s" % b", ".join(others).decode())
    acts.append("ListBuckets shows only %s" % a.bucket)
    for d in a.deny:
        for was, m, p, q, body in (("LIST", "GET", "/" + d, {"list-type": "2", "max-keys": "1"}, b""),
                                   ("PUT", "PUT", "/%s/%sforbidden.txt" % (d, a.prefix), None, b"x")):
            st, b = s3.req(m, p, q, body)
            if st != 403:
                raise S3Error("%s on %s: HTTP %s instead of 403 (the key must not be allowed anything there!)" % (was, d, st))
        acts.append("%s: LIST/PUT denied (403)" % d)
    return False, acts, "Roundtrip ok, %d foreign buckets blocked" % len(a.deny)


def cmd_purge(a):
    ak, sk = read_env(a.root_env, ["RUSTFS_ACCESS_KEY", "RUSTFS_SECRET_KEY"])
    root = S3(a.endpoint, ak, sk)
    if not a.prefix or a.prefix in ("/", ""):
        raise S3Error("purge only with a prefix")
    st, b = root.req("GET", "/" + a.bucket, {"versions": "", "prefix": a.prefix})
    check(st, b, (200,), "Read versions")
    acts = []
    for block in re.findall(rb"<(?:Version|DeleteMarker)>(.*?)</(?:Version|DeleteMarker)>", b, re.S):
        k = re.search(rb"<Key>([^<]+)</Key>", block).group(1).decode()
        v = re.search(rb"<VersionId>([^<]+)</VersionId>", block).group(1).decode()
        if not k.startswith(a.prefix):
            continue
        st, bb = root.req("DELETE", "/%s/%s" % (a.bucket, k), {"versionId": v})
        check(st, bb, (204, 200), "Delete version %s" % k)
        acts.append("%s (%s) permanently deleted" % (k, v[:8]))
    return bool(acts), acts, "%d test version(s) removed" % len(acts)


def root_s3(a):
    ak, sk = read_env(a.root_env, ["RUSTFS_ACCESS_KEY", "RUSTFS_SECRET_KEY"])
    return S3(a.endpoint, ak, sk)


def cmd_buckets(a):
    st, b = root_s3(a).req("GET", "/")
    check(st, b, (200,), "ListBuckets")
    names = [html.unescape(n.decode()) for n in re.findall(rb"<Name>([^<]+)</Name>", b)]
    return False, sorted(names), "%d Bucket(s)" % len(names)


def all_versions(root, bucket):
    """Returns [(key, versionId, size)] for all versions + delete markers."""
    out, km, vm = [], "", ""
    while True:
        q = {"versions": "", "max-keys": "1000"}
        if km:
            q["key-marker"] = km
            q["version-id-marker"] = vm
        st, b = root.req("GET", "/" + bucket, q)
        check(st, b, (200,), "Read versions %s" % bucket)
        for block in re.findall(rb"<(?:Version|DeleteMarker)>(.*?)</(?:Version|DeleteMarker)>", b, re.S):
            k = html.unescape(re.search(rb"<Key>([^<]*)</Key>", block).group(1).decode())
            v = re.search(rb"<VersionId>([^<]*)</VersionId>", block).group(1).decode()
            g = re.search(rb"<Size>(\d+)</Size>", block)
            out.append((k, v, int(g.group(1)) if g else 0))
        if not re.search(rb"<IsTruncated>true</IsTruncated>", b):
            return out
        km = html.unescape(re.search(rb"<NextKeyMarker>([^<]*)</NextKeyMarker>", b).group(1).decode())
        m = re.search(rb"<NextVersionIdMarker>([^<]*)</NextVersionIdMarker>", b)
        vm = m.group(1).decode() if m else ""


def cmd_drop_bucket(a):
    if not a.bucket or "/" in a.bucket:
        raise S3Error("drop-bucket: bucket name invalid")
    root = root_s3(a)
    st, b = root.req("HEAD", "/" + a.bucket)
    if st == 404:
        return False, [], "%s: does not exist (nothing to do)" % a.bucket
    check(st, b, (200,), "Check bucket %s" % a.bucket)
    vers = all_versions(root, a.bucket)
    by = sum(g for _, _, g in vers)
    mb = by / 1048576.0
    info = "%s: %d version(s)/marker(s), %.1f MiB (%d bytes)" % (a.bucket, len(vers), mb, by)
    if a.check:
        return True, [info], info
    for k, v, _ in vers:
        q = {"versionId": v} if v and v != "null" else {"versionId": "null"}
        st, bb = root.req("DELETE", "/%s/%s" % (a.bucket, k), q)
        check(st, bb, (204, 200, 404), "Delete version %s/%s" % (a.bucket, k))
    st, b = root.req("GET", "/" + a.bucket, {"uploads": ""})
    if st == 200:
        for block in re.findall(rb"<Upload>(.*?)</Upload>", b, re.S):
            k = html.unescape(re.search(rb"<Key>([^<]*)</Key>", block).group(1).decode())
            u = re.search(rb"<UploadId>([^<]*)</UploadId>", block).group(1).decode()
            root.req("DELETE", "/%s/%s" % (a.bucket, k), {"uploadId": u})
    st, b = root.req("DELETE", "/" + a.bucket)
    check(st, b, (204, 200), "Delete bucket %s" % a.bucket)
    return True, [info + " -> deleted"], "%s deleted (%.1f MiB)" % (a.bucket, mb)


def main():
    p = argparse.ArgumentParser(description="rustfs S3 helper (stage 8a)")
    sub = p.add_subparsers(dest="cmd", required=True)
    for n in ("health", "ensure", "roundtrip", "purge", "buckets", "drop-bucket"):
        s = sub.add_parser(n)
        s.add_argument("--endpoint", required=True)
        s.add_argument("--wait", type=int, default=90,
                       help="Seconds to wait while rustfs starts (503/no connection)")
        if n == "health":
            s.add_argument("--version", default="")
        if n in ("ensure", "purge", "buckets", "drop-bucket"):
            s.add_argument("--root-env", required=True)
        if n in ("ensure", "roundtrip", "purge", "drop-bucket"):
            s.add_argument("--bucket", required=True)
        if n in ("roundtrip", "purge"):
            s.add_argument("--prefix", default="stage8a-verify/")
        if n == "ensure":
            s.add_argument("--user-env", required=True)
            s.add_argument("--policy", required=True)
            s.add_argument("--policy-json", required=True)
            s.add_argument("--versioning", choices=("on", "off"), default="on")
            s.add_argument("--noncurrent-days", type=int, default=0)
            s.add_argument("--check", action="store_true")
        if n == "roundtrip":
            s.add_argument("--user-env", default="")
            s.add_argument("--deny", action="append", default=[])
        if n == "drop-bucket":
            s.add_argument("--check", action="store_true")
    a = p.parse_args()
    S3.wait = min(a.wait, 5) if getattr(a, "check", False) else a.wait
    try:
        changed, acts, message = globals()["cmd_" + a.cmd.replace("-", "_")](a)
        print(json.dumps({"ok": True, "changed": changed, "actions": acts, "message": message}))
        return 0
    except S3Error as e:
        if getattr(a, "check", False) and "not reachable" in str(e):
            print(json.dumps({"ok": True, "changed": True, "actions": [],
                              "message": "Check mode: rustfs not reachable yet (%s)" % e}))
            return 0
        print(json.dumps({"ok": False, "changed": False, "actions": [], "message": str(e)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
