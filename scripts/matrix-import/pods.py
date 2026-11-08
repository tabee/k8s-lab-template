#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""pods.py: build the two helper pods of scripts/matrix-import.sh as JSON (printed to stdout).

  pods.py db IMAGE HOST PORT DBNAME SSLMODE SECRET     psql pod; credentials from SECRET (keys username, password)
  pods.py files < deployment.json                      the image, user and PVC of the live Synapse pod, but it only
                                                       sleeps and mounts only /data and /tmp (no secrets, no DB access)

Both pods carry the label app.kubernetes.io/name=matrix-import (never synapse: the Service and the NetworkPolicy of
Synapse must not pick them up), run restricted (PSA) and without a service account token.
"""
import json
import sys

LABELS = {"app.kubernetes.io/name": "matrix-import", "app.kubernetes.io/part-of": "matrix-import"}
RESTRICTED = {
    "allowPrivilegeEscalation": False,
    "readOnlyRootFilesystem": True,
    "runAsNonRoot": True,
    "capabilities": {"drop": ["ALL"]},
    "seccompProfile": {"type": "RuntimeDefault"},
}


def secret_env(name, secret, key):
    return {"name": name, "valueFrom": {"secretKeyRef": {"name": secret, "key": key}}}


def pod(name, component, spec):
    spec.setdefault("restartPolicy", "Never")
    spec["automountServiceAccountToken"] = False
    spec["terminationGracePeriodSeconds"] = 5
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {"name": name, "labels": dict(LABELS, **{"app.kubernetes.io/component": component})},
        "spec": spec,
    }


def db_pod(image, host, port, dbname, sslmode, secret):
    # The CNPG image is minimal (no shell, no sleep): psql itself is the keep-alive process (one idle
    # connection in pg_sleep), all work is done with kubectl exec ... psql.
    c = {
        "name": "psql",
        "image": image,
        "command": ["psql", "-X", "-q", "-At", "-c", "SELECT pg_sleep(14400)"],
        "env": [
            {"name": "PGHOST", "value": host},
            {"name": "PGPORT", "value": port},
            {"name": "PGDATABASE", "value": dbname},
            {"name": "PGSSLMODE", "value": sslmode},
            {"name": "PGCONNECT_TIMEOUT", "value": "15"},
            {"name": "PGOPTIONS", "value": "-c client_min_messages=warning -c tcp_keepalives_idle=20 -c tcp_keepalives_interval=5 -c tcp_keepalives_count=3"},
            secret_env("PGUSER", secret, "username"),
            secret_env("PGPASSWORD", secret, "password"),
        ],
        "securityContext": RESTRICTED,
        "resources": {"requests": {"cpu": "20m", "memory": "64Mi"}, "limits": {"memory": "512Mi"}},
        # Ready only when the database answers. A new pod can reach the network a moment after it started
        # (NetworkPolicy programming), so the first connect may fail: Always restarts the container until it works.
        "readinessProbe": {"exec": {"command": ["psql", "-X", "-q", "-At", "-c", "SELECT 1"]},
                           "periodSeconds": 3, "timeoutSeconds": 10, "failureThreshold": 3},
    }
    return pod("matrix-import-db", "db", {
        "restartPolicy": "Always",
        "securityContext": {"runAsNonRoot": True, "runAsUser": 26, "runAsGroup": 26,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [c],
    })


def files_pod(dep):
    t = dep["spec"]["template"]["spec"]
    c = json.loads(json.dumps(t["containers"][0]))
    keep = {"name", "image", "securityContext"}
    for key in list(c):
        if key not in keep:
            c.pop(key)
    c["name"] = "matrix-import"
    c["command"] = ["sleep", "14400"]
    c["env"] = [{"name": "PYTHONDONTWRITEBYTECODE", "value": "1"}, {"name": "HOME", "value": "/tmp"}]
    c["securityContext"] = dict(RESTRICTED, runAsNonRoot=True)
    c["resources"] = {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"memory": "768Mi"}}
    wanted = ("data", "tmp")
    mounts = [m for m in t["containers"][0].get("volumeMounts", []) if m["name"] in wanted]
    c["volumeMounts"] = [{"name": m["name"], "mountPath": m["mountPath"]} for m in mounts]
    if {m["name"] for m in mounts} != set(wanted):
        raise SystemExit("the Synapse deployment has no data and tmp volume mounts")
    spec = {
        "securityContext": t.get("securityContext", {}),
        "containers": [c],
        "volumes": [v for v in t.get("volumes", []) if v["name"] in wanted],
    }
    return pod("matrix-import-files", "files", spec)


def main(a):
    if len(a) == 8 and a[1] == "db":
        out = db_pod(*a[2:8])
    elif len(a) == 2 and a[1] == "files":
        out = files_pod(json.load(sys.stdin))
    else:
        sys.stderr.write(__doc__)
        return 2
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
