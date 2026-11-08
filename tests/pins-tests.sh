#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for the image pins of issue #10, without a cluster and without network:
#   1. every explicit image reference in gitops/ and ansible/ carries a digest (@sha256:<64 hex>)
#   2. the probe image is defined in ONE place (group_vars/all/images.yml); no second literal anywhere
#   3. docs name the same pins as the code (probe image digest, tags of whoami, python, static-web-server, Traefik)
#   4. Traefik values: digest + versionOverride, and both chart values are what the pin check compares
#   5. the pin assert of ansible/verify-traefik.yml, run against fake cluster data: green, and red for each drift
#   6. the pin helper scripts/pins-online.py: offline behaviour (no network needed)
# Needs: python3 with PyYAML. ansible-playbook is optional (SKIP line without it).
# Usage: bash tests/pins-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
python3 -c 'import yaml' 2> /dev/null || { echo "SKIP: python3 PyYAML is missing"; exit 0; }
mkdir -p "$HOME/.cache/lab-sh-tests"
T=$(mktemp -d -p "$HOME/.cache/lab-sh-tests")
# shellcheck disable=SC2064
trap "rm -rf '$T'" EXIT
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }
has() { grep -Fq -- "$2" "$3"; ok "$1" "$?" 0; }

PIN=$(sed -n 's/^lab_probe_image: *//p' "$R/ansible/inventory/group_vars/all/images.yml")
PIN_TAG=${PIN%@*}
PIN_TAG=${PIN_TAG##*/}

echo "== 1. every explicit image reference has a digest"
cat > "$T/scan-pins.py" << 'PY'
import fnmatch
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

def repo_files(repo, sub, pattern="*"):
    """Sorted files below repo/sub that belong to the lab: what git tracks or would track (git ls-files,
    when repo is the git top level), otherwise a walk that skips every folder starting with a dot (export
    tree, test copies). Ignored folders such as ansible/.ansible/collections (installed third-party
    collections, present on every operator machine) are never scanned."""
    repo = Path(repo)
    try:
        top = subprocess.run(["git", "-C", str(repo), "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
        if top and Path(top).resolve() == repo.resolve():
            out = subprocess.run(["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", sub], capture_output=True, check=True).stdout
            names = [n for n in out.decode("utf-8").split("\0") if n]
            return sorted(p for p in (repo / n for n in names) if p.is_file() and fnmatch.fnmatch(p.name, pattern))
    except (OSError, subprocess.CalledProcessError):
        pass
    found = []
    for dirpath, dirs, files in os.walk(repo / sub):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        found += [Path(dirpath) / f for f in files if fnmatch.fnmatch(f, pattern)]
    return sorted(found)



root = Path(sys.argv[1])
bad, total = [], 0
digest = re.compile(r"@sha256:[a-f0-9]{64}$")
for sub in ("gitops", "ansible"):
    for path in repo_files(root, sub):
        if path.suffix not in (".yml", ".yaml", ".j2", ".sh", ".tpl"):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(r"""(?:^|\s)(?:image:|-\s*"?--image=)[ \t]*"?([^\s"]+)"?""", text, flags=re.M):
            ref = m.group(1)
            if "{{" in ref or "__IMG__" in ref or ref in (">-", "|", "|-", ">"):
                continue  # a variable: the value is checked where it is defined
            total += 1
            if not digest.search(ref):
                bad.append("%s: %s" % (path.relative_to(root), ref))
for path in repo_files(root, "gitops", "values*.yaml"):
    # Helm values: an image block with `repository:` needs @sha256 in `tag:` or a `digest:` key; a block that
    # only carries `digest:` (versionOverride style) must hold a well-formed one.
    stack = [yaml.safe_load(path.read_text(encoding="utf-8"))]
    while stack:
        node = stack.pop()
        if isinstance(node, list):
            stack.extend(node)
        elif isinstance(node, dict):
            stack.extend(node.values())
            if "repository" in node or "digest" in node:
                total += 1
                pinned = "@sha256:" in str(node.get("tag", "")) or re.fullmatch(r"sha256:[a-f0-9]{64}", str(node.get("digest", "")))
                if not pinned:
                    bad.append("%s: image block %s has no digest" % (path.relative_to(root), node.get("repository", "(digest only)")))
    for key in ("images",):
        block = yaml.safe_load(path.read_text(encoding="utf-8")).get(key)
        for name, ref in (block or {}).items():
            total += 1
            if not digest.search(str(ref)):
                bad.append("%s: images.%s: %s" % (path.relative_to(root), name, ref))
for path in sorted((root / "ansible/inventory/group_vars/all").glob("*.yml")):
    for m in re.finditer(r"^\w*image\w*:[ \t]*(\S+)[ \t]*$", path.read_text(encoding="utf-8"), flags=re.M):
        total += 1
        if not digest.search(m.group(1)):
            bad.append("%s: %s" % (path.name, m.group(1)))
print("checked %d image references" % total)
for b in bad:
    print("UNPINNED " + b)
sys.exit(1 if bad else 0)
PY
python3 "$T/scan-pins.py" "$R" > "$T/refs.out" 2>&1
rc=$?
cat "$T/refs.out"
ok "all explicit image references are pinned by digest" "$rc" 0
ok "the scan sees at least 12 references (the scan itself works)" "$([ "$(sed -n 's/^checked \([0-9]*\).*/\1/p' "$T/refs.out")" -ge 12 ] && echo yes || echo no)" yes

# The scan reads what the lab owns, not folders that only exist on an operator machine: ansible/.ansible/
# (installed collections, gitignored) holds unpinned test fixtures. Same tiny tree without git (walk) and with git.
S=$T/scan-tree
mkdir -p "$S/gitops" "$S/ansible/.ansible/collections/x" "$S/ansible/venv"
printf '%s\n' 'image: busybox' > "$S/ansible/.ansible/collections/x/pods.yml"
printf '%s\n' 'image: busybox' > "$S/ansible/venv/pods.yml"
printf '%s\n' "image: docker.io/library/busybox:1.37@sha256:$(printf 'a%.0s' $(seq 64))" > "$S/gitops/ok.yaml"
python3 "$T/scan-pins.py" "$S" > "$T/scan1.out" 2>&1
ok "scan without git: a dot folder (ansible/.ansible) is not scanned" "$(grep -c 'UNPINNED ansible/.ansible' "$T/scan1.out")" 0
printf '%s\n' '.ansible/' 'venv/' > "$S/.gitignore"
git -C "$S" init -q . && git -C "$S" add -A
python3 "$T/scan-pins.py" "$S" > "$T/scan2.out" 2>&1
ok "scan with git: ignored folders (ansible/.ansible, ansible/venv) are not scanned" "$(grep -c 'UNPINNED ansible/' "$T/scan2.out")" 0
printf '%s\n' 'image: busybox' > "$S/gitops/bad.yaml"
python3 "$T/scan-pins.py" "$S" > "$T/scan3.out" 2>&1
ok "scan with git: a real unpinned image in gitops/ is still red" "$?" 1
has "scan with git: names the unpinned file" "UNPINNED gitops/bad.yaml: busybox" "$T/scan3.out"
rm "$S/.gitignore"
rm -rf "$S/.git"
python3 "$T/scan-pins.py" "$S" > "$T/scan4.out" 2>&1
ok "scan without git: a real unpinned image in gitops/ is still red" "$?" 1

echo "== 2. the probe image has one definition"
ok "images.yml pins tag and digest" "$(printf '%s' "$PIN" | grep -Ec '^docker\.io/library/busybox:[0-9.]+@sha256:[a-f0-9]{64}$')" 1
# Literal tag outside images.yml (docs are checked in section 3, tests may name it).
others=$(grep -rIl --exclude-dir='.*' --exclude-dir=docs --exclude-dir=tests --exclude=images.yml -e "$PIN_TAG" "$R/ansible" "$R/gitops" "$R/scripts" || true)
ok "no second literal of $PIN_TAG in ansible/, gitops/ or scripts/" "${others:-none}" none
ok "the egress probe image is pinned separately (python)" "$(grep -c '^egress_probe_image: .*@sha256:' "$R/ansible/inventory/group_vars/all/egress.yml")" 1

echo "== 3. docs name the same pins"
bad_docs=$(grep -rIn --include='*.md' -e "$PIN_TAG" "$R/docs" | grep -v "$PIN" || true)
ok "every docs line with $PIN_TAG names the full pin (tag@digest)" "${bad_docs:-none}" none
V=$R/docs/reference/versions.md
for pair in "traefik/whoami:|gitops/workloads/whoami/deployment.yaml" "library/python:|gitops/workloads/docs/deployment.yaml" \
  "joseluisq/static-web-server:|gitops/workloads/docs/deployment.yaml"; do
  prefix=${pair%%|*}
  file=${pair##*|}
  ref=$(grep -o "${prefix}[^@ ]*" "$R/$file" | head -n 1)
  tag=${ref#*:}
  has "versions.md names ${ref} (tag as in $file)" "$tag" "$V"
done
PROXY_REF=$(sed -n 's/^  proxy: *//p' "$R/gitops/charts/notes-site/values.yaml")
has "versions.md names the oauth2-proxy tag (as in the notes chart values)" "$(t=${PROXY_REF#*:}; printf %s "${t%%@*}")" "$V"
ok "notes chart: images.proxy is tag@digest" "$(printf '%s' "$PROXY_REF" | grep -Ec '^quay\.io/oauth2-proxy/oauth2-proxy:v[0-9.]+@sha256:[a-f0-9]{64}$')" 1
TV=$R/gitops/platform/traefik/values.yaml
TTAG=$(sed -n 's/^versionOverride: *//p' "$TV")
has "versions.md names the Traefik image version $TTAG" "$TTAG" "$V"

echo "== 4. Traefik values"
ok "image.digest is sha256:<64 hex>" "$(grep -Ec '^  digest: sha256:[a-f0-9]{64}( |$)' "$TV")" 1
ok "versionOverride is set next to the digest" "$(grep -Ec '^versionOverride: v[0-9.]+$' "$TV")" 1
ok "no image tag next to the digest (the chart takes the digest first, a tag would only mislead)" "$(grep -Ec '^  tag:' "$TV")" 0
has "values.yaml comment names the online check" "scripts/pins-online.py --check" "$TV"

echo "== 5. the pin assert of verify-traefik.yml against fake cluster data"
if ! command -v ansible-playbook > /dev/null 2>&1; then
  echo "SKIP: ansible-playbook is missing"
else
  python3 - "$R" "$T" << 'PY'
import sys
import yaml
root, tmp = sys.argv[1:3]
play = yaml.safe_load(open(root + "/ansible/verify-traefik.yml", encoding="utf-8"))[0]
wanted = [t for t in play["tasks"] if t.get("name", "").startswith("The running Traefik is the pinned digest")]
assert len(wanted) == 1, "pin assert not found exactly once"
values = yaml.safe_load(open(root + "/gitops/platform/traefik/values.yaml", encoding="utf-8"))
digest = values["image"]["digest"]
rev = "42.1.3"


def case(name, **over):
    data = {
        "traefik_values": values,
        "verify_traefik_deploy": {"resources": [{
            "metadata": {"labels": {"helm.sh/chart": "traefik-" + rev}},
            "spec": {"template": {"spec": {"containers": [{"image": "docker.io/traefik@" + digest}]}}}}]},
        "verify_app": {"resources": [{"spec": {"sources": [
            {"chart": "traefik", "targetRevision": rev}, {"repoURL": "ssh://x", "targetRevision": "main"}]}}]},
        "verify_pods": {"resources": [{"status": {"containerStatuses": [{"imageID": "docker.io/traefik@" + digest}]}}]},
    }
    data.update(over)
    pb = [{"name": name, "hosts": "localhost", "connection": "local", "gather_facts": False, "vars": data, "tasks": wanted}]
    yaml.safe_dump(pb, open("%s/pin-%s.yml" % (tmp, name), "w", encoding="utf-8"))


case("green")
case("wrong-image", verify_traefik_deploy={"resources": [{
    "metadata": {"labels": {"helm.sh/chart": "traefik-" + rev}},
    "spec": {"template": {"spec": {"containers": [{"image": "docker.io/traefik:v3.7.16"}]}}}}]})
case("chart-label", verify_traefik_deploy={"resources": [{
    "metadata": {"labels": {"helm.sh/chart": "traefik-41.0.0"}},
    "spec": {"template": {"spec": {"containers": [{"image": "docker.io/traefik@" + digest}]}}}}]})
case("pod-other-digest", verify_pods={"resources": [{"status": {"containerStatuses": [{"imageID": "docker.io/traefik@sha256:" + "0" * 64}]}}]})
case("no-deployment", verify_traefik_deploy={"resources": []})
bad = dict(values)
bad["image"] = {"digest": "sha256:short"}
case("bad-digest", traefik_values=bad)
nover = dict(values)
nover.pop("versionOverride")
case("no-version-override", traefik_values=nover)
PY
  ansible-playbook -i localhost, "$T/pin-green.yml" > "$T/pin.out" 2>&1
  ok "pin assert: green case passes" "$?" 0
  for c in wrong-image chart-label pod-other-digest no-deployment bad-digest no-version-override; do
    ansible-playbook -i localhost, "$T/pin-$c.yml" > "$T/pin.out" 2>&1
    ok "pin assert: $c case fails" "$?" 2
    has "pin assert: $c case names the drift" "Traefik pin drift" "$T/pin.out"
  done
fi

echo "== 6. pins-online.py offline"
python3 "$R/scripts/pins-online.py" --help > "$T/o.out" 2>&1
ok "pins-online.py --help works" "$?" 0
python3 "$R/scripts/pins-online.py" --check --offline > "$T/o.out" 2>&1
ok "pins-online.py --check --offline reads all pins and exits 0" "$?" 0
has "pins-online.py lists the Traefik pin" "traefik" "$T/o.out"
has "pins-online.py says that the online part was skipped" "SKIP" "$T/o.out"
P=$T/pr
mkdir -p "$P/gitops/platform/traefik" "$P/ansible/inventory/group_vars/all" "$P/gitops/apps"
cp "$R/gitops/platform/traefik/values.yaml" "$P/gitops/platform/traefik/"
cp "$R/gitops/apps/traefik.yaml" "$P/gitops/apps/"
cp "$R/ansible/inventory/group_vars/all/"{images,egress,sops,backup_s3}.yml "$P/ansible/inventory/group_vars/all/"
sed -i 's/^versionOverride: .*/versionOverride: not-a-version/' "$P/gitops/platform/traefik/values.yaml"
python3 "$R/scripts/pins-online.py" --repo "$P" --check --offline > "$T/o.out" 2>&1
ok "pins-online.py refuses a malformed versionOverride" "$?" 1

echo "== 7. CI lint workflow and scripts/ci-lint.sh"
WF=$R/.github/workflows/lint.yml
[ -f "$WF" ] || WF=$R/.github/workflows/lint.yml  # the public export keeps the workflow under .github
ok "lint.yml exists" "$([ -f "$WF" ] && echo yes || echo no)" yes
wf_image=$(sed -n 's/^ *image: *//p' "$WF")
egress_image=$(sed -n 's/^egress_probe_image: *//p' "$R/ansible/inventory/group_vars/all/egress.yml")
ok "the lint workflow container is the egress_probe_image (one pin, two places)" "$wf_image" "$egress_image"
has "the workflow runs scripts/ci-lint.sh" "bash scripts/ci-lint.sh" "$WF"
has "the workflow installs the tools with --require-hashes" "--require-hashes -r ci/requirements-lint.txt" "$WF"
has "the workflow installs the collections from ansible/requirements.yml" "ansible-galaxy collection install -r ansible/requirements.yml" "$WF"
ok "the workflow uses no curl, wget or apt" "$(grep -Ec '(curl|wget|apt-get|apt install)' "$WF" | tr -d ' ')" 0
ok "every pip install in the workflow uses --require-hashes" "$(grep -E 'pip"? install' "$WF" | grep -vc -e '--require-hashes' | tr -d ' ')" 0
unhashed=$(grep -E '^[a-z0-9]' "$R/ci/requirements-lint.txt" | grep -vc ' \\$' || true)
ok "every package in ci/requirements-lint.txt carries hashes (continuation lines)" "$unhashed" 0
ok "ci/requirements-lint.txt pins ansible-lint, yamllint, shellcheck-py and ansible-core" "$(grep -Ec '^(ansible-lint|yamllint|shellcheck-py|ansible-core)==' "$R/ci/requirements-lint.txt")" 4
if command -v yamllint > /dev/null 2>&1; then
  ok "the workflow is itself clean for yamllint" "$(yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' "$WF" > /dev/null 2>&1 && echo yes || echo no)" yes
else
  echo "SKIP: yamllint is not installed (pipx install yamllint, or: sudo apt install yamllint): the workflow file is not linted here"
fi

SWF=$R/.github/workflows/security.yml
[ -f "$SWF" ] || SWF=$R/.github/workflows/security.yml
ok "security.yml exists" "$([ -f "$SWF" ] && echo yes || echo no)" yes
ok "the security workflow container is the egress_probe_image too" "$(sed -n 's/^ *image: *//p' "$SWF")" "$egress_image"
ok "the security workflow installs the Python tools with --require-hashes" "$(grep -E 'pip"? install' "$SWF" | grep -vc -e '--require-hashes' | tr -d ' ')" 0
ok "the security workflow uses no third-party action (no 'uses:' line)" "$(grep -Ec '^ *(- )?uses:' "$SWF" | tr -d ' ')" 0
ok "the security workflow asks for contents: read only" "$(grep -c '^  contents: read$' "$SWF" | tr -d ' ')" 1
ok "the security workflow has no write permission" "$(grep -Ec ': write' "$SWF" | tr -d ' ')" 0

# Negative runs on a tiny repository: each kind of defect turns ci-lint.sh red, a clean one green.
L=$T/lint
mkdir -p "$L/scripts" "$L/ansible" "$L/tests"
cp "$R/scripts/ci-lint.sh" "$L/scripts/"
cp "$R/ansible/.ansible-lint" "$L/ansible/"
printf '%s\n' '---' 'key: value' > "$L/good.yml"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$1"' > "$L/scripts/good.sh"
printf '%s\n' '---' '- name: Demo' '  hosts: localhost' '  gather_facts: false' '  tasks:' '    - name: Say hello' '      ansible.builtin.debug:' '        msg: hello' > "$L/ansible/site.yml"
git -C "$L" init -q . && git -C "$L" add -A
lint() { (cd "$L" && git add -A && bash scripts/ci-lint.sh "$@" > "$T/lint.out" 2>&1); }
if command -v yamllint > /dev/null 2>&1 && command -v shellcheck > /dev/null 2>&1; then
  lint yaml
  ok "ci-lint yaml: clean file is green" "$?" 0
  printf '%s\n' 'a: [unclosed' > "$L/bad.yml"
  lint yaml
  ok "ci-lint yaml: a broken file is red" "$?" 1
  rm "$L/bad.yml"
  lint shell
  ok "ci-lint shell: clean script is green" "$?" 0
  printf '%s\n' '#!/usr/bin/env bash' 'rm -rf $1/' 'x=$(ls | wc -l' > "$L/tests/bad.sh"
  lint shell
  ok "ci-lint shell: a script with a shellcheck warning is red" "$?" 1
  printf '%s\n' '#!/usr/bin/env bash' 'for f in $(ls); do echo "$f"; done' > "$L/tests/bad.sh"
  lint shell
  ok "ci-lint shell: an unquoted loop over ls is red" "$?" 1
  rm "$L/tests/bad.sh"
  has "ci-lint prints the file counts" "shellcheck: " "$T/lint.out"
else
  echo "SKIP: yamllint or shellcheck is not installed (sudo apt install yamllint shellcheck, or: pipx install yamllint): the ci-lint yaml and shell cases are not run"
fi
lint bogus
ok "ci-lint: an unknown mode exits 2" "$?" 2
if command -v ansible-lint > /dev/null 2>&1; then
  lint ansible
  ok "ci-lint ansible: a clean playbook is green" "$?" 0
  printf '%s\n' '---' '- name: Demo' '  hosts: localhost' '  gather_facts: false' '  tasks:' '    - ansible.builtin.debug:' '        msg: no task name' > "$L/ansible/site.yml"
  lint ansible
  ok "ci-lint ansible: a task without a name is red" "$?" 1
else
  echo "SKIP: ansible-lint is not installed (pipx install ansible-lint): the ci-lint ansible cases are not run"
fi
(cd "$L" && /usr/bin/env PATH=/nonexistent /bin/bash scripts/ci-lint.sh yaml > "$T/lint.out" 2>&1)
ok "ci-lint: a missing tool exits 2" "$?" 2
has "ci-lint: a missing tool is a SKIP with an install hint" "SKIP yamllint: not installed. Install: " "$T/lint.out"

# Missing tools in mode "all": every tool that is there still runs; a missing one is a SKIP with a hint (exit 2),
# a red check still wins (exit 1). Fake tools in a PATH of their own: no real yamllint, shellcheck or ansible-lint.
SH=$T/shim
mkdir -p "$SH"
for c in git grep dirname bash; do ln -s "$(command -v "$c")" "$SH/$c"; done
lintall() { (cd "$L" && /usr/bin/env PATH="$SH" /bin/bash scripts/ci-lint.sh "${1:-all}" > "$T/lint.out" 2>&1); }
lintall
ok "ci-lint all: no tool at all exits 2" "$?" 2
has "ci-lint all: SKIP yamllint" "SKIP yamllint: not installed" "$T/lint.out"
has "ci-lint all: SKIP shellcheck" "SKIP shellcheck: not installed" "$T/lint.out"
has "ci-lint all: SKIP ansible-lint (does not stop at the first missing tool)" "SKIP ansible-lint: not installed" "$T/lint.out"
has "ci-lint all: says that not everything ran" "NOT everything ran" "$T/lint.out"
printf '%s\n' '#!/bin/sh' 'echo fake-ansible-lint-ran' 'exit 0' > "$SH/ansible-lint"
chmod +x "$SH/ansible-lint"
lintall
ok "ci-lint all: a tool that is there runs although others are missing (still exit 2)" "$?" 2
has "ci-lint all: the present tool ran" "fake-ansible-lint-ran" "$T/lint.out"
printf '%s\n' '#!/bin/sh' 'echo fake-ansible-lint-red' 'exit 2' > "$SH/ansible-lint"
lintall
ok "ci-lint all: a red check wins over a missing tool (exit 1)" "$?" 1
has "ci-lint all: ends with RED" "ci-lint: RED (all)" "$T/lint.out"
for c in yamllint shellcheck; do printf '%s\n' '#!/bin/sh' 'exit 0' > "$SH/$c"; chmod +x "$SH/$c"; done
printf '%s\n' '#!/bin/sh' 'exit 0' > "$SH/ansible-lint"
lintall
ok "ci-lint all: all three tools there and green exits 0" "$?" 0

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
