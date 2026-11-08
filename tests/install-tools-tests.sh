#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline installer regression tests: isolated HOME/PATH, no host package changes.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PYTEST'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

root = Path.cwd()
failures = 0

def ok(label, condition):
    global failures
    print(("OK " if condition else "FAIL ") + label, flush=True)
    failures += not condition

with tempfile.TemporaryDirectory(prefix="control-tools-tests-") as temp:
    work = Path(temp)
    repo = work / "repo"
    for folder in ("scripts", "ci", "ansible"):
        (repo / folder).mkdir(parents=True)
    for file in ("scripts/install-tools.sh", "ci/control-tools.env", "ci/requirements-control.txt", "ci/requirements-security.txt", "ansible/requirements.yml"):
        shutil.copy(root / file, repo / file)
    bins, home, cache = work / "bin", work / "home", work / "cache"
    for folder in (bins, home, cache):
        folder.mkdir()
    # Deliberately omit the real control tools and sudo from PATH.
    for cmd in ("bash", "dirname", "uname", "sed", "python3", "mktemp", "rm", "cp", "basename", "sha256sum", "mkdir", "tar", "gzip", "unzip", "install", "mv", "id"):
        (bins / cmd).symlink_to(shutil.which(cmd))
    trace = work / "trace"
    def stub(name, body):
        p = bins / name
        if p.is_symlink():
            p.unlink()
        p.write_text("#!/usr/bin/env bash\nset -eu\n" + body + "\n")
        p.chmod(0o755)
    stub("dpkg-query", 'if [ "${MISSING_APT:-0}" = 1 ]; then exit 1; fi; printf "install ok installed"')
    for cmd in ("sudo", "apt-get", "curl"):
        stub(cmd, f'echo {cmd} >> "$TRACE"; exit 98')
    security_lock = (repo / "ci/requirements-security.txt").read_text()
    zizmor_version = next(line.split("==", 1)[1].split()[0] for line in security_lock.splitlines() if line.startswith("zizmor=="))
    stub("zizmor", 'echo "zizmor ' + zizmor_version + '"')
    versions = {}
    for line in (root / "ci/control-tools.env").read_text().splitlines():
        if "_VERSION=" in line:
            k, v = line.split("=", 1)
            versions[k] = v
    pintext = (repo / "ci/control-tools.env").read_text()
    for tool in ("tofu", "kubectl", "helm", "sops", "age"):
        version = versions[tool.upper() + "_VERSION"]
        def content(name):
            output = {"tofu": "OpenTofu v" + version, "kubectl": json.dumps({"clientVersion": {"gitVersion": "v" + version}}), "helm": "v" + version + "+g123", "sops": "sops " + version, "age": "v" + version, "age-keygen": "v" + version}[name]
            return "#!/usr/bin/env bash\nprintf '%s\\n' '" + output + "'\n"
        stage = work / tool
        stage.mkdir()
        ext = ".zip" if tool == "tofu" else (".tgz" if tool in ("helm", "age") else ".bin")
        archive = cache / (tool + ext)
        if tool in ("tofu", "helm", "age"):
            members = {"tofu": ["tofu"], "helm": ["linux-amd64/helm"], "age": ["age/age", "age/age-keygen"]}[tool]
            for member in members:
                file = stage / member
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(content(file.name))
                file.chmod(0o755)
            if tool == "tofu":
                with zipfile.ZipFile(archive, "w") as z:
                    z.write(stage / "tofu", "tofu")
            else:
                with tarfile.open(archive, "w:gz") as t:
                    for member in members:
                        t.add(stage / member, arcname=member)
        else:
            archive.write_text(content(tool))
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        import re
        pintext = re.sub(rf"^{tool.upper()}_URL=.*$", f"{tool.upper()}_URL=https://example.invalid/{archive.name}", pintext, flags=re.M)
        pintext = re.sub(rf"^{tool.upper()}_SHA256=.*$", f"{tool.upper()}_SHA256={sha}", pintext, flags=re.M)
    (repo / "ci/control-tools.env").write_text(pintext)
    env = dict(os.environ, HOME=str(home), PATH=f"{home}/.local/bin:{bins}", PIPX_HOME=str(home / ".local/share/pipx"), CONTROL_TOOLS_CACHE=str(cache), TRACE=str(trace))
    env.pop("LAB_TOOLS_EXTRA", None)
    def run(*args, **extra):
        return subprocess.run([str(bins / "bash"), str(repo / "scripts/install-tools.sh"), *args], env=dict(env, **extra), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    def snapshot():
        return {str(p.relative_to(home)): (p.read_bytes(), p.stat().st_mtime_ns) for p in home.rglob("*") if p.is_file()}
    r = run("--check", "--skip-ansible")
    ok("check missing exits one", r.returncode == 1)
    ok("check lists every release tool", all("missing/wrong " + t in r.stdout for t in ("tofu", "kubectl", "helm", "sops", "age")))
    ok("check never calls sudo, apt, or network", not trace.exists())
    ok("check does not create files in HOME", not list(home.iterdir()))
    r = run("--dry-run", "--skip-ansible", MISSING_APT="1")
    ok("dry-run plans packages and binaries", r.returncode == 0 and "would apt-get install" in r.stdout and "would install tofu" in r.stdout)
    ok("dry-run never mutates or elevates", not list(home.iterdir()) and not trace.exists())
    r = run("--skip-apt", "--skip-ansible")
    ok("installs verified archives", r.returncode == 0 and "changes 5" in r.stdout)
    if r.returncode:
        print(r.stdout)
    ok("age includes age-keygen", (home / ".local/bin/age-keygen").is_file())
    before = snapshot()
    r = run("--skip-apt", "--skip-ansible")
    ok("second install changes zero", r.returncode == 0 and "changes 0" in r.stdout and snapshot() == before)
    ok("installed versions print ok", all(f"ok {t} {versions[t.upper() + '_VERSION']}" in r.stdout for t in ("tofu", "kubectl", "helm", "sops", "age")))
    r = run("--check", "--skip-ansible")
    ok("check installed exits zero", r.returncode == 0)
    before = snapshot()
    r = run("--skip-apt", "--skip-ansible", PATH=str(bins))
    ok("missing local bin in PATH warns but does not reinstall", r.returncode == 0 and "WARNING:" in r.stdout and "changes 0" in r.stdout and snapshot() == before)
    r = run("--check", "--skip-ansible", MISSING_APT="1")
    ok("check missing apt exits one without sudo", r.returncode == 1 and not trace.exists())
    tofu = home / ".local/bin/tofu"
    tofu.write_text("#!/usr/bin/env bash\necho 'OpenTofu v0.1.0'\n")
    r = run("--check", "--skip-apt", "--skip-ansible")
    ok("wrong version fails check", r.returncode == 1 and "missing/wrong tofu" in r.stdout)
    before = snapshot()
    r = run("--no-upgrade", "--skip-apt", "--skip-ansible")
    ok("no-upgrade preserves wrong version and fails", r.returncode == 1 and snapshot() == before)
    r = run("--skip-apt", "--skip-ansible")
    ok("wrong version replaced by pin", r.returncode == 0 and "installed tofu" in r.stdout)
    tofu.unlink()
    bad = cache / "tofu.zip"
    original = bad.read_bytes()
    bad.write_bytes(b"corrupted")
    r = run("--skip-apt", "--skip-ansible")
    ok("checksum mismatch aborts before install", r.returncode == 1 and "SHA-256 mismatch" in r.stdout and not tofu.exists())
    bad.write_bytes(original)
    r = run("--no-upgrade", "--skip-apt", "--skip-ansible")
    ok("no-upgrade still installs missing tool", r.returncode == 0 and tofu.exists())
    keygen = home / ".local/bin/age-keygen"
    original_keygen = keygen.read_text()
    keygen.write_text("#!/usr/bin/env bash\necho 'v0.1.0'\n")
    before = snapshot()
    r = run("--no-upgrade", "--skip-apt", "--skip-ansible")
    ok("no-upgrade preserves a mismatched age-keygen", r.returncode == 1 and snapshot() == before)
    keygen.write_text(original_keygen)
    keygen.unlink()
    r = run("--check", "--skip-apt", "--skip-ansible")
    ok("missing companion binary fails check", r.returncode == 1 and "missing/wrong age" in r.stdout)
    run("--skip-apt", "--skip-ansible")
    r = run("--check", "--skip-apt", "--skip-ansible", LAB_TOOLS_EXTRA="site-tool")
    ok("site-specific extras checked without guessing packages", r.returncode == 1 and "missing extra site-tool" in r.stdout)
    r = run("--check", "--skip-apt")
    ok("missing pipx environment and collections fail check", r.returncode == 1 and "missing/wrong ansible-core" in r.stdout and "missing/wrong kubernetes.core" in r.stdout and not trace.exists())
    # Fake a complete pipx environment without importing or touching host packages.
    venv = home / ".local/share/pipx/venvs/ansible-core/bin"
    venv.mkdir(parents=True)
    py = venv / "python"
    py.write_text("#!/usr/bin/env bash\ncase \"${@: -1}\" in ansible-core) echo \"$CORE_VERSION\";; kubernetes) [ -n \"${KUBE_VERSION:-}\" ] || exit 1; echo \"$KUBE_VERSION\";; jsonpatch) if [ -f \"$HOME/jsonpatch-installed\" ] || [ \"${MISSING_JSONPATCH:-0}\" != 1 ]; then echo \"$JSONPATCH_VERSION\"; else exit 1; fi;; esac\n")
    py.chmod(0o755)
    for name in ("ansible", "ansible-playbook"):
        p = home / ".local/bin" / name
        p.write_text("#!/usr/bin/env bash\nexit 0\n")
        p.chmod(0o755)
    galaxy = home / ".local/bin/ansible-galaxy"
    collection_versions = {"ansible.posix": "2.2.2", "community.general": "13.5.0", "kubernetes.core": "6.6.0"}
    manifests = {}
    for name, value in collection_versions.items():
        namespace, short = name.split(".")
        manifest = home / ".ansible/collections/ansible_collections" / namespace / short / "MANIFEST.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({"collection_info": {"version": value}}))
        manifests[name] = manifest
    galaxy.write_text("#!/usr/bin/env python3\n" +
        "import json,os,sys\nfrom pathlib import Path\n" +
        "name,version=sys.argv[-1].split(':')\nnamespace,short=name.split('.')\n" +
        "p=Path(os.environ['HOME'])/'.ansible/collections/ansible_collections'/namespace/short/'MANIFEST.json'\n" +
        "p.write_text(json.dumps({'collection_info':{'version':version}}))\n")
    galaxy.chmod(0o755)
    full = dict(CORE_VERSION=versions["ANSIBLE_CORE_VERSION"], KUBE_VERSION=versions["KUBERNETES_PYTHON_VERSION"], JSONPATCH_VERSION=versions["JSONPATCH_VERSION"])
    r = run("--check", "--skip-apt", **full)
    ok("check inspects pinned pipx packages and all collections", r.returncode == 0 and "ok ansible.posix 2.2.2" in r.stdout and "ok kubernetes.core 6.6.0" in r.stdout)
    before = snapshot()
    r = run("--skip-apt", **full)
    ok("complete installed toolchain has no changes", r.returncode == 0 and "changes 0" in r.stdout and snapshot() == before)
    protected = dict(full, CORE_VERSION="0.1.0", KUBE_VERSION="")
    before = snapshot()
    r = run("--no-upgrade", "--skip-apt", **protected)
    ok("no-upgrade cannot upgrade core via a missing Kubernetes dependency", r.returncode == 1 and snapshot() == before and not trace.exists())
    r = run("--check", "--skip-apt", **dict(full, KUBE_VERSION="0.1.0"))
    ok("wrong Python Kubernetes package fails check", r.returncode == 1 and "missing/wrong kubernetes" in r.stdout)
    manifests["kubernetes.core"].write_text(json.dumps({"collection_info": {"version": "0.0.1"}}))
    r = run("--check", "--skip-apt", **full)
    ok("wrong collection version fails check", r.returncode == 1)
    r = run("--skip-apt", **full)
    ok("wrong collection is replaced", r.returncode == 0 and "installed kubernetes.core 6.6.0" in r.stdout)
    before = snapshot()
    r = run("--skip-apt", **full)
    ok("second collection install changes zero", r.returncode == 0 and "changes 0" in r.stdout and snapshot() == before)
    r = run("--check", "--dry-run", "--skip-apt")
    ok("dry-run cannot override check semantics", r.returncode == 2)
    # sudo is permitted only for the apt branch, once for validation then noninteractive.
    stub("id", "echo 1000")
    stub("sudo", 'echo "sudo $*" >> "$TRACE"; if [ "$1" = -v ]; then exit 0; fi; [ "$1" = -n ]; shift; "$@"')
    stub("apt-get", 'echo "apt-get $*" >> "$TRACE"; : > "$HOME/apt-installed"')
    stub("dpkg-query", 'if [ "${@: -1}" = jq ] && [ ! -f "$HOME/apt-installed" ]; then exit 1; fi; printf "install ok installed"')
    r = run("--skip-ansible")
    log = trace.read_text()
    ok("apt installs only the missing package", r.returncode == 0 and "apt-get install -y jq" in log)
    ok("sudo is validated exactly once and apt uses noninteractive sudo", log.splitlines().count("sudo -v") == 1 and log.count("sudo -n apt-get") == 2)
    trace.unlink()
    r = run("--skip-ansible")
    ok("apt second run never calls sudo or apt", r.returncode == 0 and not trace.exists() and "changes 0" in r.stdout)
    before = snapshot()
    r = run("--check", "--skip-apt", **full)
    ok("complete check does not change HOME metadata or content", r.returncode == 0 and snapshot() == before)
    # Exercise pipx injection without downloading Python packages or running pip.
    # The bootstrap stub emits one fake wheel whose hash is pinned in the fixture.
    fake_wheel = b"offline-core-wheel"
    core_sha = hashlib.sha256(fake_wheel).hexdigest()
    pin = (repo / "ci/control-tools.env").read_text()
    pin = re.sub(r"^ANSIBLE_CORE_URL=.*$", "ANSIBLE_CORE_URL=https://example.invalid/core.whl", pin, flags=re.M)
    pin = re.sub(r"^ANSIBLE_CORE_SHA256=.*$", "ANSIBLE_CORE_SHA256=" + core_sha, pin, flags=re.M)
    (repo / "ci/control-tools.env").write_text(pin)
    bootstrap_stub = work / "bootstrap-python"
    bootstrap_stub.write_text("#!/usr/bin/env bash\nprintf offline-core-wheel > \"${@: -1}/core.whl\"\n")
    bootstrap_stub.chmod(0o755)
    real_python = str((bins / "python3").resolve())
    stub("python3", 'if [ "$1" = -m ] && [ "$2" = venv ]; then mkdir -p "$3/bin"; cp "$BOOTSTRAP_STUB" "$3/bin/python"; exit 0; fi; exec ' + real_python + ' "$@"')
    stub("pipx", 'case "${@: -1}" in jsonpatch=="$JSONPATCH_VERSION") : > "$HOME/jsonpatch-installed";; *) exit 87;; esac')
    dep_env = dict(full, MISSING_JSONPATCH="1", BOOTSTRAP_STUB=str(bootstrap_stub))
    r = run("--skip-apt", **dep_env)
    ok("missing jsonpatch is injected as jsonpatch, not as Kubernetes", r.returncode == 0 and "installed jsonpatch " + versions["JSONPATCH_VERSION"] in r.stdout)
    before = snapshot()
    r = run("--skip-apt", **dep_env)
    ok("second Python dependency install has no changes", r.returncode == 0 and "changes 0" in r.stdout and snapshot() == before)
    # Exercise security installs with fake pip/pipx: no network or host mutations.
    (bins / "zizmor").unlink()
    r = run("--check", "--skip-apt", "--skip-ansible")
    ok("missing zizmor fails check without network", r.returncode == 1 and "missing/wrong zizmor" in r.stdout and not trace.exists())
    r = run("--dry-run", "--skip-apt", "--skip-ansible")
    ok("dry-run plans pinned zizmor without network", r.returncode == 0 and "would install zizmor " + zizmor_version in r.stdout and not trace.exists())
    bootstrap_stub.write_text("#!/usr/bin/env bash\necho \"download $*\" >> \"$TRACE\"\n[ \"${FAIL_DOWNLOAD:-0}\" != 1 ] || exit 91\n")
    stub("pipx", 'echo "pipx $*" >> "$TRACE"; mkdir -p "$HOME/.local/bin"; cp "$ZIZMOR_STUB" "$HOME/.local/bin/zizmor"; chmod +x "$HOME/.local/bin/zizmor"')
    zizmor_stub = work / "zizmor-stub"
    zizmor_stub.write_text('#!/usr/bin/env bash\necho "zizmor ' + zizmor_version + '"\n')
    (bins / "chmod").symlink_to(shutil.which("chmod"))
    security_env = dict(BOOTSTRAP_STUB=str(bootstrap_stub), ZIZMOR_STUB=str(zizmor_stub))
    r = run("--skip-apt", "--skip-ansible", **security_env, FAIL_DOWNLOAD="1")
    ok("failed security hash download prevents pipx installation", r.returncode == 91 and "pipx " not in trace.read_text() and not (home / ".local/bin/zizmor").exists())
    trace.unlink()
    r = run("--skip-apt", "--skip-ansible", **security_env)
    log = trace.read_text()
    ok("zizmor downloads the hash-checked security lock before offline pipx", r.returncode == 0 and "pip download --require-hashes --only-binary=:all:" in log and "requirements-security.txt" in log and "pipx install --force --pip-args=--no-index --find-links=" in log and "zizmor==" + zizmor_version in log)
    trace.unlink()
    before = snapshot()
    r = run("--skip-apt", "--skip-ansible", **security_env)
    ok("second zizmor install is idempotent", r.returncode == 0 and "changes 0" in r.stdout and snapshot() == before and not trace.exists())
    stub("zizmor", 'echo "zizmor 0.1.0"')
    # Local bin still takes precedence; change it to exercise --no-upgrade.
    (home / ".local/bin/zizmor").write_text('#!/usr/bin/env bash\necho "zizmor 0.1.0"\n')
    before = snapshot()
    r = run("--no-upgrade", "--skip-apt", "--skip-ansible", **security_env)
    ok("no-upgrade preserves mismatched zizmor", r.returncode == 1 and snapshot() == before and not trace.exists())
    (home / ".local/bin/zizmor").write_text('#!/usr/bin/env bash\necho "zizmor ' + zizmor_version + '"\n')
    (repo / "ansible/requirements.yml").write_text("collections: [unexpected-schema]\n")
    r = run("--check", "--skip-apt", **full)
    ok("malformed collection pins fail closed", r.returncode == 1 and "ERROR:" in r.stdout)
    r = run("--nonsense")
    ok("unknown flag exits two", r.returncode == 2)
    stub("uname", "echo aarch64")
    r = run("--check")
    ok("unsupported architecture fails before changes", r.returncode == 2 and "only Linux amd64" in r.stdout and not trace.exists())
# The real pins must agree with the human reference and k3s, without network access.
text = (root / "docs/reference/versions.md").read_text()
for name, value in versions.items():
    ok("version reference contains " + name, "`" + value + "`" in text)
import yaml
k3s = yaml.safe_load((root / "ansible/inventory/group_vars/k3s/main.yml").read_text())["k3s_version"]
ok("kubectl matches k3s patch", "v" + versions["KUBECTL_VERSION"] == k3s.split("+")[0])
lock = (root / "ci/requirements-control.txt").read_text()
ok("Python lock agrees with pins", "ansible-core==" + versions["ANSIBLE_CORE_VERSION"] in lock and "kubernetes==" + versions["KUBERNETES_PYTHON_VERSION"] in lock and "jsonpatch==" + versions["JSONPATCH_VERSION"] in lock)
raise SystemExit(1 if failures else 0)
PYTEST
