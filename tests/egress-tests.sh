#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for the egress policies of issue #5, without a cluster:
#   1. scripts/repo-egress.py in a sandbox copy (dry-run, apply, check, drift, several CIDRs, port,
#      refused values, resolve with an IP-literal URL)
#   2. structure of the NetworkPolicy files under gitops/ (default-deny, allowed targets, values equal lab.yaml)
#   3. notes chart (helm template), lab-customize round trip, probe image, marker blocks
#   4. Ansible: verify-egress.yml syntax, rendered probe sets, the verify playbooks include the probes
# Needs: python3 with PyYAML. helm and ansible-playbook are optional (SKIP lines without them).
# Usage: bash tests/egress-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
python3 -c 'import yaml' 2> /dev/null || { echo "SKIP: python3 PyYAML is missing"; exit 0; }
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
TMPPB="$R/ansible/.egress-render-test.yml"
# shellcheck disable=SC2064
trap "rm -rf '$T'; rm -f '$TMPPB'" EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }
hasnt() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 1; }

# ---------- Sandbox copy of everything the script touches
S=$T/repo
mkdir -p "$S/scripts" "$S/infra/envs/local"
cp "$R/scripts/repo-egress.py" "$S/scripts/"
cp "$R/infra/envs/local/lab.yaml" "$S/infra/envs/local/lab.yaml"
for f in gitops/workloads/argocd/networkpolicy.yaml gitops/workloads/docs/networkpolicy.yaml gitops/charts/notes-site/values.yaml; do
  mkdir -p "$S/$(dirname "$f")"
  cp "$R/$f" "$S/$f"
done
# The sandbox always starts in the committed (placeholder) state, also after the owner has run
# "lab.sh repo-egress" in the real tree: reset the marker blocks to the placeholder and port 22.
mkdir -p "$S/gitops/charts"
cp -r "$R/gitops/charts/notes-site" "$S/gitops/charts/"
ln -s "$R/docs" "$S/docs"  # files/build.sh and files/requirements.txt of the chart are links into docs/
python3 - "$S" <<'PY'
import re, sys
from pathlib import Path
lab = Path(sys.argv[1]) / "infra/envs/local/lab.yaml"
lab.write_text(re.sub(r"^github_repo_url:.*$", "github_repo_url: ssh://git@github.com/test-owner/k8s-lab.git",
                      lab.read_text(), flags=re.M))
for rel in ("gitops/workloads/argocd/networkpolicy.yaml", "gitops/workloads/docs/networkpolicy.yaml", "gitops/charts/notes-site/values.yaml"):
    p = sys.argv[1] + "/" + rel
    t = open(p, encoding="utf-8").read()
    t = re.sub(r"^([ \t]*)# lab-egress:repo-cidrs BEGIN\n(?:.*\n)*?[ \t]*# lab-egress:repo-cidrs END", r"\1# lab-egress:repo-cidrs BEGIN\n\1- ipBlock:\n\1    cidr: 203.0.113.10/32\n\1# lab-egress:repo-cidrs END", t, flags=re.M)
    t = re.sub(r"^([ \t]*)# lab-egress:repo-port BEGIN\n[ \t]*([A-Za-z]+): [0-9]+\n", r"\1# lab-egress:repo-port BEGIN\n\1\2: 22\n", t, flags=re.M)
    open(p, "w", encoding="utf-8").write(t)
PY
# Untouched copy of the chart in the placeholder state (for the helm checks at the end).
mkdir -p "$T/p0/gitops/charts"
cp -r "$S/gitops/charts/notes-site" "$T/p0/gitops/charts/"
ln -s "$R/docs" "$T/p0/docs"
RE() { python3 "$S/scripts/repo-egress.py" --repo "$S" "$@" > "$T/out" 2>&1; }
sums() { (cd "$S" && sha256sum gitops/workloads/argocd/networkpolicy.yaml gitops/workloads/docs/networkpolicy.yaml gitops/charts/notes-site/values.yaml infra/envs/local/lab.yaml); }
FILES="gitops/workloads/argocd/networkpolicy.yaml gitops/workloads/docs/networkpolicy.yaml gitops/charts/notes-site/values.yaml"

echo "== repo-egress.py"
RE --check; ok "committed state: --check refuses the placeholder" "$?" 1
has "committed state: message names the command" "bash scripts/lab.sh repo-egress --resolve" "$T/out"
RE; ok "committed state: apply refuses the placeholder" "$?" 1
has "apply with the placeholder: ABORT" "ABORT" "$T/out"
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid:2200/me/k8s-lab.git --dry-run; ok "dry-run: exit 0" "$?" 0
has "dry-run: WOULD CHANGE" "WOULD CHANGE" "$T/out"
S0=$(sums)
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid:2200/me/k8s-lab.git --dry-run
ok "dry-run writes nothing" "$(sums)" "$S0"
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid:2200/me/k8s-lab.git; ok "apply: exit 0" "$?" 0
n_edit=$(grep -c '^EDIT' "$T/out")
ok "apply: all three files edited" "$n_edit" 3
for f in $FILES; do has "apply: $f has the /32 block" "cidr: 192.0.2.7/32" "$S/$f"; done
has "apply: docs policy has the port" "port: 2200" "$S/gitops/workloads/docs/networkpolicy.yaml"
has "apply: argocd policy has the port" "port: 2200" "$S/gitops/workloads/argocd/networkpolicy.yaml"
has "apply: notes values have the port (key kept)" "repoPort: 2200" "$S/gitops/charts/notes-site/values.yaml"
S1=$(sums)
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid:2200/me/k8s-lab.git; ok "apply again: exit 0" "$?" 0
has "apply again: SKIP" "SKIP" "$T/out"
ok "apply again: byte-identical" "$(sums)" "$S1"
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid:2200/me/k8s-lab.git --check; ok "check after apply: exit 0" "$?" 0
sed -i 's#cidr: 192.0.2.7/32#cidr: 192.0.2.8/32#' "$S/gitops/workloads/docs/networkpolicy.yaml"
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid:2200/me/k8s-lab.git --check; ok "check: drifted address: exit 1" "$?" 1
has "check: DRIFT names the file" "DRIFT: gitops/workloads/docs/networkpolicy.yaml" "$T/out"
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid:2200/me/k8s-lab.git; ok "apply repairs the drift" "$?" 0
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid:2200/me/k8s-lab.git --check; ok "check after repair: exit 0" "$?" 0
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid/me/k8s-lab.git --check; ok "check: port from repo_url differs (22 vs 2200): exit 1" "$?" 1
has "check: DRIFT names the port" "port" "$T/out"
RE --cidrs "192.0.2.7, 198.51.100.0/28" --repo-url ssh://git@git.lab-test.invalid/me/k8s-lab.git; ok "several CIDRs: exit 0" "$?" 0
for f in $FILES; do has "several CIDRs: $f has the second block" "cidr: 198.51.100.0/28" "$S/$f"; done
has "no port in repo_url: 22" "port: 22" "$S/gitops/workloads/docs/networkpolicy.yaml"
S2=$(sums)
RE --cidrs "198.51.100.0/28,192.0.2.7" --repo-url ssh://git@git.lab-test.invalid/me/k8s-lab.git --dry-run
has "different order is a change (the file is a list)" "WOULD CHANGE" "$T/out"
ok "dry-run still writes nothing" "$(sums)" "$S2"
python3 - "$S/gitops/workloads/docs/networkpolicy.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
egress = [d for d in docs if d["metadata"]["name"] == "docs-allow-egress"][0]
cidrs = [t["ipBlock"]["cidr"] for r in egress["spec"]["egress"] for t in r.get("to", []) if "ipBlock" in t and "except" not in t["ipBlock"]]
sys.exit(0 if cidrs == ["192.0.2.7/32", "198.51.100.0/28"] else 1)
PY
ok "the edited docs policy is still valid YAML with both CIDRs" "$?" 0
for bad in 127.0.0.1 10.0.0.0/8 ::1 0.0.0.0 224.0.0.1 169.254.1.1 203.0.113.10 not-an-ip 192.0.2.0/23 ""; do
  S3=$(sums)
  RE --cidrs "$bad" --repo-url ssh://git@git.lab-test.invalid/me/k8s-lab.git; ok "refused value '$bad': exit 1" "$?" 1
  has "refused value '$bad': ABORT" "ABORT" "$T/out"
  ok "refused value '$bad': nothing written" "$(sums)" "$S3"
done
RE --cidrs 192.0.2.7 --repo-url not-a-url; ok "unreadable repo_url: exit 1" "$?" 1
cp "$S/gitops/charts/notes-site/values.yaml" "$T/values.keep"
sed -i '/lab-egress:repo-port END/d' "$S/gitops/charts/notes-site/values.yaml"
RE --cidrs 192.0.2.7 --repo-url ssh://git@git.lab-test.invalid/me/k8s-lab.git; ok "missing marker: exit 1" "$?" 1
has "missing marker: the message names the file" "values.yaml" "$T/out"
cp "$T/values.keep" "$S/gitops/charts/notes-site/values.yaml"

echo "== repo-egress.py --resolve (IP-literal URL, no network)"
cp "$S/infra/envs/local/lab.yaml" "$T/lab.yaml.keep"
RE --resolve --repo-url ssh://git@git.example.org/YOUR-NAME/k8s-lab.git < /dev/null; ok "resolve: placeholder URL: exit 1" "$?" 1
has "resolve: placeholder URL message" "placeholder" "$T/out"
RE --resolve --repo-url ssh://git@127.0.0.1:2200/me/k8s-lab.git < /dev/null; ok "resolve: loopback only: exit 1" "$?" 1
RE --resolve --repo-url ssh://git@198.51.100.7:2200/me/k8s-lab.git < /dev/null; ok "resolve: no question, writes the file: exit 0" "$?" 0
has "resolve: lab.local.yaml has the address" "repo_egress_cidrs: 198.51.100.7" "$S/infra/envs/local/lab.local.yaml"
ok "resolve: new lab.local.yaml mode 600" "$(stat -c %a "$S/infra/envs/local/lab.local.yaml")" 600
RE --resolve --repo-url ssh://git@198.51.100.7:2200/me/k8s-lab.git < /dev/null; ok "resolve again: exit 0" "$?" 0
has "resolve again: SKIP" "SKIP" "$T/out"
RE --resolve --repo-url ssh://git@198.51.100.9:2200/me/k8s-lab.git < /dev/null; ok "resolve: other address replaces the line: exit 0" "$?" 0
ok "resolve: exactly one repo_egress_cidrs line" "$(grep -c '^repo_egress_cidrs:' "$S/infra/envs/local/lab.local.yaml")" 1
has "resolve: new address" "repo_egress_cidrs: 198.51.100.9" "$S/infra/envs/local/lab.local.yaml"
printf 'repo_url: ssh://git@198.51.100.9:2200/me/k8s-lab.git\n' >> "$S/infra/envs/local/lab.local.yaml"
RE; ok "apply from lab.local.yaml (address and port): exit 0" "$?" 0
has "apply from lab.local.yaml: address" "cidr: 198.51.100.9/32" "$S/gitops/workloads/argocd/networkpolicy.yaml"
has "apply from lab.local.yaml: port" "port: 2200" "$S/gitops/workloads/argocd/networkpolicy.yaml"
RE --check; ok "check from lab.local.yaml: exit 0" "$?" 0
hasnt "no value of lab.yaml or secrets in the output" "AGE-SECRET-KEY" "$T/out"
ok "lab.yaml is never edited by the script" "$(cmp -s "$T/lab.yaml.keep" "$S/infra/envs/local/lab.yaml"; echo $?)" 0

echo "== repo-egress.py with source: github (ADR 0024)"
G=$T/gh
cp -a "$S" "$G"
rm -f "$G/infra/envs/local/lab.local.yaml"
printf 'source: github\n' > "$G/infra/envs/local/lab.local.yaml"
RG() { python3 "$G/scripts/repo-egress.py" --repo "$G" "$@" > "$T/out" 2>&1; }
printf '{"git":["192.30.252.0/22","185.199.108.0/22","140.82.112.0/20","143.55.64.0/20","20.201.28.151/32"],"web":["192.30.252.0/22"]}\n' > "$T/meta.json"
RG --dry-run; ok "github: dry-run: exit 0" "$?" 0
has "github: dry-run would change the policies" "WOULD CHANGE" "$T/out"
RG; ok "github: apply: exit 0" "$?" 0
for f in gitops/workloads/argocd/networkpolicy.yaml gitops/workloads/docs/networkpolicy.yaml gitops/charts/notes-site/values.yaml; do
  has "github: $f has the GitHub range 140.82.112.0/20" "140.82.112.0/20" "$G/$f"
  has "github: $f has the GitHub range 192.30.252.0/22" "192.30.252.0/22" "$G/$f"
  hasnt "github: $f has no placeholder" "203.0.113.10" "$G/$f"
done
has "github: SSH port 22" "port: 22" "$G/gitops/workloads/argocd/networkpolicy.yaml"
RG --check; ok "github: check after apply: exit 0" "$?" 0
printf 'source: gitea\nrepo_egress_cidrs: 192.0.2.7\nrepo_url: ssh://git@git.lab-test.invalid:2200/me/k8s-lab.git\n' > "$G/infra/envs/local/lab.local.yaml"
RG --check; ok "back on gitea without apply: drift, exit 1" "$?" 1
has "back on gitea: DRIFT named" "DRIFT" "$T/out"
printf 'source: github\n' > "$G/infra/envs/local/lab.local.yaml"
RG --check; ok "github again: exit 0" "$?" 0
for bad in 10.0.0.0/8 140.82.96.0/19 127.0.0.1 not-an-ip ""; do
  RG --cidrs "$bad"; ok "github: refused value '$bad': exit 1" "$?" 1
  has "github: refused value '$bad': the key is github_egress_cidrs" "github_egress_cidrs" "$T/out"
done
RG --cidrs 140.82.112.0/20; ok "github: a /20 is accepted" "$?" 0
RE --cidrs 140.82.112.0/20 --repo-url ssh://git@git.lab-test.invalid/me/k8s-lab.git; ok "gitea mode: the same /20 is refused" "$?" 1
has "gitea mode: the limit is /24" "wider than /24" "$T/out"
RG --repo-url ssh://git@git.lab-test.invalid/me/k8s-lab.git; ok "github: another host is refused" "$?" 1
has "github: another host message" "github.com only" "$T/out"
printf 'source: svn\n' > "$G/infra/envs/local/lab.local.yaml"
RG --check; ok "invalid source: exit 1" "$?" 1
has "invalid source message" "source must be gitea or github" "$T/out"
printf 'source: github\n' > "$G/infra/envs/local/lab.local.yaml"
RG --resolve --meta-file "$T/meta.json" --addrs 140.82.121.3; ok "github resolve: exit 0" "$?" 0
has "github resolve: the range that holds the address" "github_egress_cidrs: 140.82.112.0/20" "$G/infra/envs/local/lab.local.yaml"
RG --resolve --meta-file "$T/meta.json" --addrs 140.82.121.3; has "github resolve again: SKIP" "SKIP" "$T/out"
RG --resolve --meta-file "$T/meta.json" --addrs 140.82.121.3,192.30.255.5,140.82.112.4; ok "github resolve: several addresses: exit 0" "$?" 0
has "github resolve: two ranges" "github_egress_cidrs: 140.82.112.0/20,192.30.252.0/22" "$G/infra/envs/local/lab.local.yaml"
ok "github resolve: exactly one github_egress_cidrs line" "$(grep -c '^github_egress_cidrs:' "$G/infra/envs/local/lab.local.yaml")" 1
RG --resolve --meta-file "$T/meta.json" --addrs 198.51.100.1; ok "github resolve: an address outside the ranges: exit 0" "$?" 0
has "github resolve: warns" "WARNING" "$T/out"
has "github resolve: preserve approved regions and append only the new address" "github_egress_cidrs: 140.82.112.0/20,192.30.252.0/22,198.51.100.1" "$G/infra/envs/local/lab.local.yaml"
RG --resolve --meta-file "$T/missing.json" --addrs 140.82.121.3; ok "github resolve: unreadable meta document: exit 1" "$?" 1
has "github resolve: unreadable meta message" "cannot read the git ranges" "$T/out"
ok "github resolve: lab.yaml is never edited" "$(cmp -s "$S/infra/envs/local/lab.yaml" "$G/infra/envs/local/lab.yaml"; echo $?)" 0
printf 'source: github\n' > "$G/infra/envs/local/lab.local.yaml"
RG --check-live --addrs 140.82.121.3; ok "check-live: inside the ranges: exit 0" "$?" 0
RG --check-live --addrs 198.51.100.1; ok "check-live: outside the ranges: exit 1" "$?" 1
has "check-live: drift names the fix" "repo-egress --resolve" "$T/out"
RG --check-live --addrs 140.82.121.3,198.51.100.1; ok "check-live: one address outside: exit 1" "$?" 1
LAB_EGRESS_ADDRS=140.82.121.3 RG --check-live; ok "check-live: addresses from LAB_EGRESS_ADDRS: exit 0" "$?" 0
printf 'source: gitea\n' > "$G/infra/envs/local/lab.local.yaml"
RG --check-live; ok "check-live with source gitea: exit 0" "$?" 0
has "check-live with source gitea: SKIP" "SKIP" "$T/out"

echo "== independent notes content egress (mixed sources, no DNS)"
M=$T/mixed
cp -a "$G" "$M"
printf '%s\n' '- name: private' '  repo: ssh://git@10.20.0.1:2300/me/notes.git' '  repo_egress_cidrs: ["10.20.0.1/32"]' > "$M/gitops/sites.yaml"
RM() { python3 "$M/scripts/repo-egress.py" --repo "$M" "$@" > "$T/out" 2>&1; }
for source in github gitea; do
  printf 'source: %s\nrepo_url: ssh://git@10.20.0.1:2300/me/k8s-lab.git\nrepo_egress_cidrs: 10.20.0.1\n' "$source" > "$M/infra/envs/local/lab.local.yaml"
  pinned=$(sha256sum "$M/gitops/sites.yaml")
  RM; ok "$source + private notes: apply succeeds" "$?" 0
  RM --check; ok "$source + private notes: offline check succeeds" "$?" 0
  RM; ok "$source + private notes: repeated apply succeeds" "$?" 0
  ok "$source: repo-egress never rewrites the content pins" "$(sha256sum "$M/gitops/sites.yaml")" "$pinned"
  python3 - "$M/gitops/charts/notes-site/values.yaml" "$M/gitops/sites.yaml" "$T/content.yaml" <<'PYNOTES'
import sys, yaml
values = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
site = yaml.safe_load(open(sys.argv[2], encoding="utf-8"))[0]
# Mirror the ApplicationSet mapping; source-mode tests render the actual chart.
values["site"].update(name=site["name"], host="notes.example.test", repo=site["repo"],
                      repoEgressCidrs=site["repo_egress_cidrs"])
with open(sys.argv[3], "w", encoding="utf-8") as f:
    yaml.safe_dump(values, f)
PYNOTES
  ok "$source: prepare chart values from sites.yaml" "$?" 0
  if command -v helm >/dev/null; then
    helm template notes "$M/gitops/charts/notes-site" --namespace notes-private -f "$T/content.yaml" > "$T/content-render.yaml" 2> "$T/content-render.err"
    ok "$source + private notes: chart renders" "$?" 0
    python3 - "$T/content-render.yaml" "$source" <<'PYNOTES'
import ipaddress, sys, yaml
rules = next(d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8"))
             if d and d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "notes-allow-egress")["spec"]["egress"]
def allowed(address, port):
    ip = ipaddress.ip_address(address)
    return any(any(p["port"] == port and p.get("protocol", "TCP") == "TCP" for p in r.get("ports", []))
               and any("ipBlock" in t and ip in ipaddress.ip_network(t["ipBlock"]["cidr"])
                       and not any(ip in ipaddress.ip_network(c) for c in t["ipBlock"].get("except", []))
                       for t in r["to"]) for r in rules)
assert allowed("10.20.0.1", 2300), "content SSH denied"
assert not allowed("10.20.0.2", 2300), "content rule is too wide"
assert not allowed("10.20.0.1", 2200), "unrelated private port allowed"
assert allowed("198.51.100.10", 443), "public HTTPS for plugins/PyPI lost (RFC 5737 stand-in for any public address)"
if sys.argv[2] == "github":
    assert allowed("140.82.121.3", 22), "GitHub SSH lost"
    assert allowed("140.82.121.3", 443), "GitHub theme/plugin HTTPS lost"
    assert not allowed("10.20.0.1", 443), "content rule unexpectedly grants private HTTPS"
PYNOTES
    ok "$source: content SSH allowed; unrelated private targets denied; plugin HTTPS preserved" "$?" 0
    for port in 22 2200; do
      repo_url=ssh://git@10.20.0.1/me/notes.git
      [ "$port" = 22 ] || repo_url=ssh://git@10.20.0.1:$port/me/notes.git
      helm template notes "$M/gitops/charts/notes-site" --namespace notes-private -f "$T/content.yaml" \
        --set-string "site.repo=$repo_url" > "$T/port-render.yaml" 2> "$T/content-render.err"
      ok "$source: content URL port $port renders" "$?" 0
      python3 - "$T/port-render.yaml" "$port" <<'PYNOTES'
import sys, yaml
rules = next(d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8"))
             if d and d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "notes-allow-egress")["spec"]["egress"]
# DNS is first; the independent content rule must be SSH-only with the URL's port.
assert rules[1] == {"to": [{"ipBlock": {"cidr": "10.20.0.1/32"}}],
                    "ports": [{"protocol": "TCP", "port": int(sys.argv[2])}]}
PYNOTES
      ok "$source: content URL supplies port $port (default 22), not the Argo source" "$?" 0
    done
  else
    echo "SKIP: helm missing (mixed-source notes policy not rendered)"
  fi
done
has "ApplicationSet passes independent content pins" 'repoEgressCidrs: {{ dig "repo_egress_cidrs" (list) . | toJson }}' "$R/gitops/apps/notes.yaml"
printf 'source: github\n' > "$M/infra/envs/local/lab.local.yaml"
cp "$M/gitops/sites.yaml" "$T/sites.keep"
for bad in '[]' '["10.0.0.0/8"]' '["127.0.0.1/32"]' '["10.20.0.1"]' '"10.20.0.1/32"'; do
  printf '%s\n' '- name: private' '  repo: ssh://git@10.20.0.1:2300/me/notes.git' "  repo_egress_cidrs: $bad" > "$M/gitops/sites.yaml"
  before=$(sha256sum "$M/gitops/charts/notes-site/values.yaml")
  RM; ok "mixed source: invalid or missing content pins $bad abort apply" "$?" 1
  ok "invalid content pins: no source policy written" "$(sha256sum "$M/gitops/charts/notes-site/values.yaml")" "$before"
done
cp "$T/sites.keep" "$M/gitops/sites.yaml"
RM; ok "mixed source: repairing pins restores apply" "$?" 0
RM --check; ok "mixed source: check after repairing pins" "$?" 0

echo "== committed policies: structure"
python3 - "$R" > "$T/struct.out" 2>&1 <<'PY'
import glob, os, re, sys
import yaml

R = sys.argv[1]
results = []


def check(name, cond):
    results.append(("OK  " if cond else "FAIL") + " " + name)


def flat(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^([a-z_0-9]+):[ \t]*(.*?)[ \t]*$", line.rstrip("\n"))
        if m and not m.group(2).startswith("#"):
            out[m.group(1)] = m.group(2).strip("\"'")
    return out


lab = flat(os.path.join(R, "infra/envs/local/lab.yaml"))
if os.path.exists(os.path.join(R, "infra/envs/local/lab.local.yaml")):
    lab.update(flat(os.path.join(R, "infra/envs/local/lab.local.yaml")))
if lab.get("source", "gitea") == "github":  # same override as lab.sh, lab.yml and repo-egress.py (ADR 0024)
    lab.update(repo_url=lab["github_repo_url"], repo_egress_cidrs=lab["github_egress_cidrs"])
s3_port = int(re.search(r"^backup_s3_port:\s*(\d+)", open(os.path.join(R, "ansible/inventory/group_vars/all/backup_s3.yml")).read(), re.M).group(1))
api = lab["vm_ip"] + "/32"
s3 = lab["gateway"] + "/32"


def load(rel):
    return [d for d in yaml.safe_load_all(open(os.path.join(R, rel), encoding="utf-8")) if d]


def nps(rel):
    return {d["metadata"]["name"]: d for d in load(rel) if d.get("kind") == "NetworkPolicy"}


def cidr_ports(np):
    """(cidr, port) pairs of all egress rules of a policy."""
    out = set()
    for rule in np["spec"].get("egress", []):
        for t in rule.get("to", []):
            if "ipBlock" in t:
                for p in rule.get("ports", []):
                    out.add((t["ipBlock"]["cidr"], p["port"]))
    return out


for ns, rel, with_k8up in (("gitea", "gitops/workloads/gitea/manifests/networkpolicy.yaml", True), ("db-lab", "gitops/workloads/db-lab/networkpolicy.yaml", False), ("matrix", "gitops/workloads/matrix/manifests/networkpolicy.yaml", True)):
    p = nps(rel)
    for name in ("default-deny-egress", "allow-egress-dns", "allow-egress-same-namespace", "allow-egress-cnpg-api-s3", "allow-egress-pooler-api"):
        check("%s: policy %s exists" % (ns, name), name in p)
    check("%s: policy allow-egress-k8up %s" % (ns, "exists" if with_k8up else "is absent"), ("allow-egress-k8up" in p) == with_k8up)
    deny = p["default-deny-egress"]["spec"]
    check("%s: default-deny-egress selects all pods and has no rule" % ns, deny["podSelector"] == {} and deny["policyTypes"] == ["Egress"] and not deny.get("egress"))
    check("%s: cnpg policy allows exactly the API and S3 (vm_ip:6443, gateway:%d)" % (ns, s3_port), cidr_ports(p["allow-egress-cnpg-api-s3"]) == {(api, 6443), (s3, s3_port)})
    check("%s: pooler policy allows exactly the API" % ns, cidr_ports(p["allow-egress-pooler-api"]) == {(api, 6443)})
    check("%s: pooler policy selects the pooler label" % ns, "cnpg.io/poolerName" in str(p["allow-egress-pooler-api"]["spec"]["podSelector"]))
    check("%s: cnpg policy selects the cluster label" % ns, "cnpg.io/cluster" in str(p["allow-egress-cnpg-api-s3"]["spec"]["podSelector"]))
    if with_k8up:
        check("%s: k8up policy selects k8upjob and allows API and S3" % ns, "k8upjob" in str(p["allow-egress-k8up"]["spec"]["podSelector"]) and cidr_ports(p["allow-egress-k8up"]) == {(api, 6443), (s3, s3_port)})
    dns = p["allow-egress-dns"]["spec"]["egress"][0]
    check("%s: DNS only to kube-dns in kube-system, port 53" % ns, "kube-system" in str(dns["to"]) and "kube-dns" in str(dns["to"]) and sorted(x["port"] for x in dns["ports"]) == [53, 53])
    same = p["allow-egress-same-namespace"]["spec"]["egress"][0]
    check("%s: same-namespace rule has no namespaceSelector and no ipBlock" % ns, same["to"] == [{"podSelector": {}}])

kc = nps("gitops/workloads/keycloak/manifests/networkpolicy.yaml")
for name in ("default-deny-egress", "allow-egress-dns", "allow-egress-same-namespace", "allow-egress-cnpg-api-s3"):
    check("keycloak: policy %s exists" % name, name in kc)
check("keycloak: no k8up and no pooler policy (no PVC, no pooler)", "allow-egress-k8up" not in kc and "allow-egress-pooler-api" not in kc)
kdeny = kc["default-deny-egress"]["spec"]
check("keycloak: default-deny-egress selects all pods and has no rule", kdeny["podSelector"] == {} and kdeny["policyTypes"] == ["Egress"] and not kdeny.get("egress"))
check("keycloak: cnpg policy allows exactly the API and S3", cidr_ports(kc["allow-egress-cnpg-api-s3"]) == {(api, 6443), (s3, s3_port)})
check("keycloak: cnpg policy selects the cluster label", "cnpg.io/cluster" in str(kc["allow-egress-cnpg-api-s3"]["spec"]["podSelector"]))
kdns = kc["allow-egress-dns"]["spec"]["egress"][0]
check("keycloak: DNS only to kube-dns in kube-system, port 53", "kube-system" in str(kdns["to"]) and "kube-dns" in str(kdns["to"]) and sorted(x["port"] for x in kdns["ports"]) == [53, 53])
check("keycloak: same-namespace rule has no namespaceSelector and no ipBlock", kc["allow-egress-same-namespace"]["spec"]["egress"][0]["to"] == [{"podSelector": {}}])
for rel, name, sel in (("gitops/workloads/gitea/manifests/networkpolicy-keycloak.yaml", "gitea-allow-egress-keycloak", "gitea"), ("gitops/workloads/matrix/manifests/networkpolicy-keycloak.yaml", "synapse-allow-egress-keycloak", "synapse")):
    kp = nps(rel)
    check("%s: client egress policy %s exists" % (sel, name), name in kp)
    krule = kp[name]["spec"]["egress"]
    check("%s: client egress goes only to the Keycloak pods on 8080" % sel, len(krule) == 1 and "keycloak" in str(krule[0]["to"]) and [x["port"] for x in krule[0]["ports"]] == [8080] and "ipBlock" not in str(krule[0]["to"]))

d = nps("gitops/workloads/docs/networkpolicy.yaml")
check("docs: docs-allow-traefik and docs-allow-egress", sorted(d) == ["docs-allow-egress", "docs-allow-traefik"])
a = nps("gitops/workloads/argocd/networkpolicy.yaml")
check("argocd: repo-server egress policy exists", "argocd-repo-server-egress" in a)
rs = a["argocd-repo-server-egress"]
check("argocd: repo-server policy selects the repo-server", "argocd-repo-server" in str(rs["spec"]["podSelector"]))
check("argocd: repo-server policy has no API rule (6443) and no S3 rule", all(p[1] not in (6443, s3_port) for p in cidr_ports(rs)))
check("argocd: repo-server policy allows redis", "argocd-redis" in str(rs["spec"]["egress"]) and 6379 in [x["port"] for r in rs["spec"]["egress"] for x in r.get("ports", [])])
check("argocd: the chart policies are untouched (no egress type added)", all("Egress" not in v["spec"].get("policyTypes", []) for k, v in a.items() if k != "argocd-repo-server-egress"))

# every egress policy: no allow-all rule, every ipBlock 0.0.0.0/0 only on 443 with the private ranges excepted
files = [rel for rel in glob.glob(os.path.join(R, "gitops", "**", "*.yaml"), recursive=True) if "{{" not in open(rel, encoding="utf-8").read()]
must_except = {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10", "127.0.0.0/8"}
bad_open = []
bad_rule = []
egress_namespaces = set()
for f in files:
    for doc in yaml.safe_load_all(open(f, encoding="utf-8")):
        if not isinstance(doc, dict) or doc.get("kind") != "NetworkPolicy" or "Egress" not in doc["spec"].get("policyTypes", []):
            continue
        egress_namespaces.add(doc["metadata"].get("namespace"))
        for rule in doc["spec"].get("egress", []):
            if not rule.get("to"):
                bad_rule.append(doc["metadata"]["name"])
            for t in rule.get("to", []):
                ib = t.get("ipBlock")
                if ib and ib["cidr"] == "0.0.0.0/0":
                    ports = [x["port"] for x in rule.get("ports", [])]
                    if ports != [443] or not must_except <= set(ib.get("except", [])):
                        bad_open.append(doc["metadata"]["name"])
check("no egress rule without a destination (no allow-all)", not bad_rule)
check("0.0.0.0/0 only on port 443 and with all private ranges excepted", not bad_open)
check("egress policies exist only in gitea, gitea-runner, gitea-runner-jobs, matrix, keycloak, db-lab, docs, argocd", egress_namespaces == {"gitea", "gitea-runner", "gitea-runner-jobs", "matrix", "keycloak", "db-lab", "docs", "argocd"})
check("no egress policy touches kube-system, cnpg-system, traefik or cert-manager", not egress_namespaces & {"kube-system", "cnpg-system", "traefik", "cert-manager"})

# notes chart template: rendered by helm in a later check; here only the source
tpl = open(os.path.join(R, "gitops/charts/notes-site/templates/networkpolicy.yaml"), encoding="utf-8").read()
check("notes template: notes-allow-egress is there", "notes-allow-egress" in tpl)
check("notes template: the excepted ranges come from the values", ".Values.egress.publicExcept" in tpl and ".Values.egress.repoTo" in tpl and ".Values.egress.repoPort" in tpl)
vals = yaml.safe_load(open(os.path.join(R, "gitops/charts/notes-site/values.yaml"), encoding="utf-8"))
check("notes values: egress.publicExcept holds all private ranges", must_except <= set(vals["egress"]["publicExcept"]))
check("notes values: egress.repoTo and repoPort are set", bool(vals["egress"]["repoTo"]) and isinstance(vals["egress"]["repoPort"], int))

# one marker pair per file, exactly the files the script edits
for rel in ("gitops/workloads/argocd/networkpolicy.yaml", "gitops/workloads/docs/networkpolicy.yaml", "gitops/charts/notes-site/values.yaml"):
    t = open(os.path.join(R, rel), encoding="utf-8").read()
    check("%s: one cidr marker pair and one port marker pair" % rel, all(t.count(m) == 1 for m in ("# lab-egress:repo-cidrs BEGIN", "# lab-egress:repo-cidrs END", "# lab-egress:repo-port BEGIN", "# lab-egress:repo-port END")))
check("the script edits exactly the files with markers", sorted(re.findall(r'"(gitops/[^"]+)"', open(os.path.join(R, "scripts/repo-egress.py"), encoding="utf-8").read().split("FILES = [")[1].split("]")[0])) == sorted(rel for rel in (os.path.relpath(f, R) for f in glob.glob(os.path.join(R, "gitops", "**", "*.yaml"), recursive=True)) if "lab-egress:repo-cidrs BEGIN" in open(os.path.join(R, rel), encoding="utf-8").read()))
# the committed blocks hold the public placeholder only in the export; here only check the shape
print("\n".join(results))
PY
while IFS= read -r line; do
  case $line in
    "OK   "*) n=$((n + 1)); echo "OK   ${line#OK   }" ;;
    "FAIL "*) n=$((n + 1)); fail=$((fail + 1)); echo "$line" ;;
    *) n=$((n + 1)); fail=$((fail + 1)); echo "FAIL structure check crashed: $line" ;;
  esac
done < "$T/struct.out"

echo "== probe image, notes chart, lab-customize round trip"
IMG=$(sed -n 's/^egress_probe_image: *//p' "$R/ansible/inventory/group_vars/all/egress.yml")
has "probe image equals the docs deployment image" "image: $IMG" "$R/gitops/workloads/docs/deployment.yaml"
has "probe image equals the notes builder image" "builder: $IMG" "$R/gitops/charts/notes-site/values.yaml"
if command -v helm > /dev/null 2>&1; then
  HSET="site.name=t,site.host=t.example.test,site.repo=ssh://git@git.example.test/me/notes.git"
  helm template notes-t "$T/p0/gitops/charts/notes-site" --namespace notes-t --set "$HSET" > "$T/helm.out" 2> "$T/helm.err"; ok "helm template notes-site: exit 0" "$?" 0
  has "helm: notes-allow-egress rendered" "name: notes-allow-egress" "$T/helm.out"
  has "helm: git server block rendered" "cidr: 203.0.113.10/32" "$T/helm.out"
  has "helm: 443 rule rendered" "port: 443" "$T/helm.out"
  has "helm: private range excepted" "10.0.0.0/8" "$T/helm.out"
  python3 - "$T/helm.out" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
np = [d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "notes-allow-egress"][0]
open_rules = [t["ipBlock"] for r in np["spec"]["egress"] for t in r["to"] if "ipBlock" in t and t["ipBlock"]["cidr"] == "0.0.0.0/0"]
sys.exit(0 if len(open_rules) == 1 and len(open_rules[0]["except"]) == 6 and np["spec"]["policyTypes"] == ["Egress"] else 1)
PY
  ok "helm: the rendered policy is valid, one 0.0.0.0/0 rule with 6 excepts" "$?" 0
  helm template notes-t "$T/p0/gitops/charts/notes-site" --namespace notes-t --set "$HSET,egress.repoPort=2200" > "$T/helm2.out" 2> /dev/null
  has "helm: port value flows into the policy" "port: 2200" "$T/helm2.out"
else
  echo "SKIP: helm is missing (notes chart not rendered)"
fi
G=$T/anp
mkdir -p "$G/scripts" "$G/infra/envs/local"
cp "$R/scripts/lab-customize.py" "$G/scripts/"
cp -r "$R/gitops" "$G/gitops"
cp "$R/zensical.toml" "$G/zensical.toml" 2> /dev/null || true
cp "$R/infra/envs/local/lab.yaml" "$G/infra/envs/local/lab.yaml"
OLD_GW=$(sed -n 's/^gateway: *//p' "$R/infra/envs/local/lab.yaml")
OLD_VM=$(sed -n 's/^vm_ip: *//p' "$R/infra/envs/local/lab.yaml")
OLD_URL=$(sed -n 's/^repo_url: *//p' "$R/infra/envs/local/lab.yaml")
OLD_DOM=$(sed -n 's/^domain: *//p' "$R/infra/envs/local/lab.yaml")
python3 "$G/scripts/lab-customize.py" --repo "$G" --domain "$OLD_DOM" --repo-url "$OLD_URL" --gateway 10.77.0.1 --vm-cidr 10.77.0.0/24 --vm-ip 10.77.0.50 --edge-ingress-cidrs 10.77.0.0/24 > "$T/anp.out" 2>&1; ok "lab-customize with other networks: exit 0" "$?" 0
for f in gitops/workloads/gitea/manifests/networkpolicy.yaml gitops/workloads/db-lab/networkpolicy.yaml gitops/workloads/matrix/manifests/networkpolicy.yaml gitops/workloads/keycloak/manifests/networkpolicy.yaml; do
  has "round trip: $f has the new API address" "cidr: 10.77.0.50/32" "$G/$f"
  has "round trip: $f has the new S3 gateway" "cidr: 10.77.0.1/32" "$G/$f"
  hasnt "round trip: $f has no old API address" "cidr: $OLD_VM/32" "$G/$f"
  hasnt "round trip: $f has no old gateway" "cidr: $OLD_GW/32" "$G/$f"
done
python3 "$G/scripts/lab-customize.py" --repo "$G" --domain "$OLD_DOM" --repo-url "$OLD_URL" --gateway 10.77.0.1 --vm-cidr 10.77.0.0/24 --vm-ip 10.77.0.50 --edge-ingress-cidrs 10.77.0.0/24 --check > "$T/anp2.out" 2>&1; ok "round trip: --check is clean" "$?" 0
# docs/notes policies keep the RFC1918 excepts (a rewrite of 192.168.122.x must not touch 192.168.0.0/16)
has "round trip: docs policy keeps 192.168.0.0/16 excepted" "192.168.0.0/16" "$G/gitops/workloads/docs/networkpolicy.yaml"

echo "== Ansible"
if command -v ansible-playbook > /dev/null 2>&1; then
  (cd "$R/ansible" && ANSIBLE_LOCALHOST_WARNING=False ansible-playbook --syntax-check verify-egress.yml > "$T/syn.out" 2>&1); ok "verify-egress.yml: syntax check" "$?" 0
  for pb in verify-gitea verify-cnpg verify-docs verify-argocd verify-notes verify-matrix verify-keycloak; do
    (cd "$R/ansible" && ANSIBLE_LOCALHOST_WARNING=False ansible-playbook --syntax-check "$pb.yml" > "$T/syn.out" 2>&1); ok "$pb.yml: syntax check" "$?" 0
  done
  cat > "$TMPPB" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.copy:
        dest: $T/probes.json
        mode: "0600"
        content: "{{ {'control': egress_probe_control, 'gitea': egress_probe_gitea, 'matrix': egress_probe_matrix, 'keycloak': egress_probe_keycloak, 'dblab': egress_probe_dblab, 'docs': egress_probe_docs, 'argocd': egress_probe_argocd, 'api': egress_t_api, 's3': egress_t_s3, 'git': egress_t_git, 'other': egress_t_other, 'lab_cidrs': lab_repo_egress_cidrs} | to_json }}"
YML
  (cd "$R/ansible" && ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False ansible-playbook .egress-render-test.yml > "$T/render.out" 2>&1); ok "probe sets render" "$?" 0
  python3 - "$R" "$T/probes.json" > "$T/probes.out" 2>&1 <<'PY'
import json, os, re, sys
R, path = sys.argv[1], sys.argv[2]
d = json.load(open(path, encoding="utf-8"))
res = []


def check(name, cond):
    res.append(("OK   " if cond else "FAIL ") + name)


def flat(p):
    out = {}
    for line in open(p, encoding="utf-8"):
        m = re.match(r"^([a-z_0-9]+):[ \t]*(.*?)[ \t]*$", line.rstrip("\n"))
        if m and not m.group(2).startswith("#"):
            out[m.group(1)] = m.group(2).strip("\"'")
    return out


lab = flat(R + "/infra/envs/local/lab.yaml")
if os.path.exists(R + "/infra/envs/local/lab.local.yaml"):
    lab.update(flat(R + "/infra/envs/local/lab.local.yaml"))
if lab.get("source", "gitea") == "github":  # same override as lab.sh, lab.yml and repo-egress.py (ADR 0024)
    lab.update(repo_url=lab["github_repo_url"], repo_egress_cidrs=lab["github_egress_cidrs"])
s3_port = re.search(r"^backup_s3_port:\s*(\d+)", open(R + "/ansible/inventory/group_vars/all/backup_s3.yml").read(), re.M).group(1)
check("API target is vm_ip:6443", d["api"] == lab["vm_ip"] + ":6443")
check("S3 target is gateway:backup_s3_port", d["s3"] == lab["gateway"] + ":" + s3_port)
m = re.match(r"^ssh://(?:[^@/]+@)?([^:/]+)(?::(\d+))?/", lab["repo_url"])
check("git target is host:port of repo_url", d["git"] == "%s:%s" % (m.group(1), m.group(2) or "22"))
check("lab_repo_egress_cidrs is a list of /32 or networks", isinstance(d["lab_cidrs"], list) and all("/" in c for c in d["lab_cidrs"]) and d["lab_cidrs"] == [c if "/" in c else c + "/32" for c in [x.strip() for x in lab["repo_egress_cidrs"].split(",")]])
allowed_ns = {"gitea", "matrix", "keycloak", "db-lab", "docs", "argocd", "egress-verify-control"}
target = re.compile(r"^[^:\s]+:[0-9]+$")
for group in ("control", "gitea", "matrix", "keycloak", "dblab", "docs", "argocd"):
    names = [p["name"] for p in d[group]]
    check("%s: probe names are unique" % group, len(names) == len(set(names)))
    for p in d[group]:
        n = p["name"]
        check("probe %s: namespace is known" % n, p["namespace"] in allowed_ns)
        check("probe %s: all targets are host:port" % n, all(target.match(t) for t in p["open"] + p["closed"]))
        check("probe %s: no target is both open and closed" % n, not set(p["open"]) & set(p["closed"]))
ctl = d["control"][0]
check("control probe: namespace is created and has no labels", ctl.get("create_namespace") is True and ctl["labels"] == {})
check("control probe: API and S3 are reachable there", {d["api"], d["s3"]} <= set(ctl["open"]))
by = {p["name"]: p for g in ("gitea", "matrix", "keycloak", "dblab", "docs", "argocd") for p in d[g]}
check("gitea-plain: nothing open, API/S3/git closed", by["gitea-plain"]["open"] == [] and {d["api"], d["s3"], d["git"]} <= set(by["gitea-plain"]["closed"]))
check("gitea-cnpg and gitea-k8up: API and S3 open, git closed", all(set(by[k]["open"]) == {d["api"], d["s3"]} and d["git"] in by[k]["closed"] for k in ("gitea-cnpg", "gitea-k8up")))
check("gitea-pooler: only the API open", by["gitea-pooler"]["open"] == [d["api"]] and d["s3"] in by["gitea-pooler"]["closed"])
check("matrix-plain: nothing open, API/S3/git closed", by["matrix-plain"]["open"] == [] and {d["api"], d["s3"], d["git"]} <= set(by["matrix-plain"]["closed"]))
check("matrix-cnpg and matrix-k8up: API and S3 open, git closed", all(set(by[k]["open"]) == {d["api"], d["s3"]} and d["git"] in by[k]["closed"] for k in ("matrix-cnpg", "matrix-k8up")))
check("matrix-pooler: only the API open", by["matrix-pooler"]["open"] == [d["api"]] and d["s3"] in by["matrix-pooler"]["closed"])
check("keycloak-plain: nothing open, API/S3/git closed", by["keycloak-plain"]["open"] == [] and {d["api"], d["s3"], d["git"]} <= set(by["keycloak-plain"]["closed"]))
check("keycloak-cnpg: API and S3 open, git closed", set(by["keycloak-cnpg"]["open"]) == {d["api"], d["s3"]} and d["git"] in by["keycloak-cnpg"]["closed"])
check("dblab-k8up-label: the k8up label opens nothing in db-lab", by["dblab-k8up-label"]["open"] == [])
check("docs: git open, API and S3 closed", by["docs"]["open"] == [d["git"]] and {d["api"], d["s3"]} <= set(by["docs"]["closed"]))
check("argocd-repo-server: git open, API closed", by["argocd-repo-server"]["open"] == [d["git"]] and d["api"] in by["argocd-repo-server"]["closed"])
check("every probe set closes the node SSH port and plain HTTP", all(set(d["other"]) <= set(p["closed"]) for p in by.values()))
print("\n".join(res))
PY
  while IFS= read -r line; do
    case $line in
      "OK   "*) n=$((n + 1)); echo "$line" ;;
      *) n=$((n + 1)); fail=$((fail + 1)); echo "FAIL ${line#FAIL }" ;;
    esac
  done < "$T/probes.out"
else
  echo "SKIP: ansible-playbook is missing (syntax checks and probe rendering not run)"
fi
for pb in verify-gitea:egress_probe_gitea verify-matrix:egress_probe_matrix verify-keycloak:egress_probe_keycloak verify-cnpg:egress_probe_dblab verify-docs:egress_probe_docs verify-argocd:egress_probe_argocd; do
  f=${pb%%:*}
  set_name=${pb##*:}
  has "$f.yml includes the egress probes" "tasks/egress-probe.yml" "$R/ansible/$f.yml"
  has "$f.yml probes: control + $set_name" "egress_probe_control + $set_name" "$R/ansible/$f.yml"
done
has "verify-egress.yml includes the egress probes" "tasks/egress-probe.yml" "$R/ansible/verify-egress.yml"
has "the probe task asserts a clean result" "DONE bad=0" "$R/ansible/tasks/egress-probe.yml"
has "the probe task removes its pods in an always block" "always:" "$R/ansible/tasks/egress-probe.yml"
has "the probe pod is PSA restricted (non-root, no privilege escalation)" "allowPrivilegeEscalation: false" "$R/ansible/tasks/egress-probe.yml"
has "the probe pod has no service account token" "automountServiceAccountToken: false" "$R/ansible/tasks/egress-probe.yml"
has "lab.sh acceptance runs verify-egress.yml" "verify-egress.yml" "$R/scripts/lab.sh"

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
