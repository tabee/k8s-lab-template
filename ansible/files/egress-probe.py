"""Egress probe (issue #5), runs inside a throwaway pod: tries TCP connections and reports.

PROBE_OPEN and PROBE_CLOSED hold space separated host:port lists. Output, one line per target:
  OK open|closed TARGET     as expected
  BAD open|closed TARGET    not as expected
  DONE bad=N                last line
The cluster DNS must always work. Exit code is always 0 (the log is the result).
"""
import os
import socket
import time


def tcp(target):
    host, port = target.rsplit(":", 1)
    try:
        socket.create_connection((host, int(port)), timeout=3).close()
        return True
    except OSError:
        return False


def targets(name):
    return [t for t in os.environ.get(name, "").split() if t]


bad = 0
# kube-router needs about a second to know a new pod: connections before that are not reliable.
time.sleep(2)
try:
    socket.getaddrinfo("kubernetes.default.svc.cluster.local", 443)
    print("OK dns cluster")
except OSError:
    print("BAD dns cluster")
    bad += 1
for target in targets("PROBE_OPEN"):
    reached = False
    for _ in range(5):
        reached = tcp(target)
        if reached:
            break
        time.sleep(2)
    print(("OK" if reached else "BAD"), "open", target)
    bad += 0 if reached else 1
for target in targets("PROBE_CLOSED"):
    reached = tcp(target)
    print(("BAD" if reached else "OK"), "closed", target)
    bad += 1 if reached else 0
print("DONE bad=%d" % bad)
