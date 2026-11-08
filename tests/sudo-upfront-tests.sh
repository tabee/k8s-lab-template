#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Run the actual Ansible become plugin with a fake sudo; never change privileges.
set -eu
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
python3 - "$R" <<'PYTEST'
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import time

source = (Path(sys.argv[1]) / "scripts/lab.sh").read_text()
def function(name, end):
    return source[source.index(name + "() {"):source.index(end)]

log_start = function("log_start", "# Stopwatch:")
assert log_start.index("ask_sudo") < log_start.index("exec >")
for command in ("up", "rebuild", "export", "purge", "acceptance", "sync-host"):
    assert command in log_start
print("OK   privileged logged commands authenticate before tee and long phases")
if not shutil.which("ansible-playbook"):
    print("SKIP: ansible-playbook missing; real local become regression not run")
    sys.exit(0)

# Public synthetic fixture, deliberately including edge whitespace, never a real password.
fixture = " local-test-password "
with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    (root / "ansible").mkdir()
    (root / "bin").mkdir()
    sudo = root / "bin/sudo"
    sudo.write_text(r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\n')
if args == ['-S', '-k', '-p', '', '-v']:
    valid = sys.stdin.readline().rstrip('\n') == ' local-test-password '
    sys.exit(0 if valid else 1)
# Do not grant a cached timestamp: every local Ansible invocation must authenticate.
prompt = args[args.index('-p') + 1]
sys.stderr.write(prompt)
sys.stderr.flush()
valid = sys.stdin.readline().rstrip('\n') == ' local-test-password '
if not valid:
    sys.exit(1)
with open(os.environ['BECOME_CALLS'], 'a') as log:
    log.write('password accepted, no tty=' + str(not sys.stdin.isatty()) + '\n')
# The test user does not exist; ignore -u and execute as the current unprivileged user.
command = args[args.index('-u') + 2:]
os.execvp(command[0], command)
""")
    sudo.chmod(0o755)
    (root / "ansible.cfg").write_text("[defaults]\nhost_key_checking=False\n")
    (root / "ansible/probe.yml").write_text("""---
- name: Local become regression
  hosts: all
  gather_facts: false
  become: true
  become_user: lab-test-user
  vars:
    ansible_pipelining: true
    ansible_python_interpreter: """ + sys.executable + """
  tasks:
    - name: Execute a module through the actual become plugin
      ansible.builtin.command: /bin/true
      changed_when: false
""")
    harness = root / "run"
    harness.write_text("""#!/usr/bin/env bash
set -euo pipefail
SUDO_PW=""
REPO=$TEST_ROOT
REQUIRE_TTY=${TEST_TTY:-1}
load_values() { W_sudo_exe="$TEST_ROOT/bin/sudo"; }
die() { echo "$*" >&2; exit 1; }
cfg() { echo "$TEST_ROOT/logs"; }
now_text() { echo test-time; }
book_ans() { :; }
trap 'SUDO_PW=""' EXIT
""" + function("ask_sudo", "# changed sum") + log_start +
        function("ans_sudo", "# ------------------------------------------------------------------ VM state") + """
log_start sync-host
# Repeated calls must not prompt again, including after a long phase/no cached sudo.
ask_sudo
ans_sudo probe.yml -i localhost, -c local || { echo TRANSPORT_FAILED; exit 1; }
ans_sudo probe.yml -i localhost, -c local || { echo TRANSPORT_FAILED; exit 1; }
echo WORK_DONE
# Drain log_start's asynchronous tee before the harness exits.
exec 1>&- 2>&-
wait
""")
    env = dict(os.environ, TEST_ROOT=td, CALLS=str(root / "calls"),
               BECOME_CALLS=str(root / "become-calls"),
               PATH=str(root / "bin") + ":" + os.environ["PATH"],
               ANSIBLE_CONFIG=str(root / "ansible.cfg"), ANSIBLE_NOCOLOR="1")
    master, slave = pty.openpty()
    def terminal():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    proc = subprocess.Popen(["bash", "-x", str(harness)], env=env, stdin=slave,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            preexec_fn=terminal)
    # stdout is a pipe, not a TTY: prompts must still use the controlling terminal.
    terminal_output = b""
    deadline = time.monotonic() + 10
    while b"not shown: " not in terminal_output or termios.tcgetattr(slave)[3] & termios.ECHO:
        assert time.monotonic() < deadline, "password prompt did not become ready"
        if select.select([master], [], [], 0.05)[0]:
            terminal_output += os.read(master, 4096)
    os.write(master, (fixture + "\n").encode())
    out, err = proc.communicate(timeout=45)
    while select.select([master], [], [], 0)[0]:
        terminal_output += os.read(master, 4096)
    os.close(slave)
    os.close(master)
    assert proc.returncode == 0 and out.count(b"failed=0") == 2, (proc.returncode, out, err)
    calls = (root / "calls").read_text()
    assert calls.count('["-S", "-k", "-p", "", "-v"]') == 1, calls
    becomes = (root / "become-calls").read_text().splitlines()
    assert becomes == ["password accepted, no tty=True"] * 2, becomes
    logs = b"".join(p.read_bytes() for p in (root / "logs").glob("*"))
    for surface in (out, err, terminal_output, calls.encode(), logs):
        assert fixture.strip().encode() not in surface, "password leaked"
    assert b"Empty password was provided" not in out + err
    print("OK   real ansible-playbook become succeeds twice without a TTY timestamp")
    print("OK   one hidden terminal prompt with piped stdout; whitespace preserved")
    print("OK   no password in argv, logs, terminal echo or bash trace")

    shutil.rmtree(root / "logs")
    for label, data, diagnostic in (
        ("empty", "\n", b"Empty sudo password refused"),
        ("wrong", "incorrect\n", b"sudo password wrong"),
        ("EOF", "", b"timed out or was cancelled"),
    ):
        (root / "calls").write_text("")
        result = subprocess.run(["bash", str(harness)], env=dict(env, TEST_TTY="0"),
                                input=data.encode(), capture_output=True, timeout=10,
                                start_new_session=True)
        assert result.returncode != 0 and diagnostic in result.stderr, (label, result)
        assert not (root / "logs").exists(), "log created before authentication"
        assert b"WORK_DONE" not in result.stdout
        if label != "wrong":
            assert not (root / "calls").read_text(), "empty password reached sudo"
        assert data.strip().encode() not in result.stdout + result.stderr if data.strip() else True
        print("OK   " + label + " input fails before logging/work; no empty password sent")
    result = subprocess.run(["bash", str(harness)], env=env, input=b"",
                            capture_output=True, timeout=10, start_new_session=True)
    assert result.returncode != 0 and b"controlling terminal" in result.stderr
    assert not (root / "logs").exists()
    print("OK   missing controlling terminal fails clearly before work")
PYTEST
