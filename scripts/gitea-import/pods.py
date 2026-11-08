#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""pods.py: build the two helper pods of scripts/gitea-import.sh as JSON (printed to stdout).

  pods.py db IMAGE HOST PORT DBNAME SSLMODE SECRET     psql pod; credentials from SECRET (keys username, password)
  pods.py files SECRET < deployment.json               a copy of the live Gitea pod (same image, env, mounts,
                                                       PVC) that only sleeps, plus the DB credentials from SECRET

Both pods carry the label app.kubernetes.io/name=gitea-import (never gitea: the NetworkPolicy and the Service
of Gitea must not pick them up), run restricted (PSA) and without a service account token.
"""
import json
import sys

LABELS = {"app.kubernetes.io/name": "gitea-import", "app.kubernetes.io/part-of": "gitea-import"}
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
            {"name": "PGOPTIONS", "value": "-c client_min_messages=warning"},
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
    return pod("gitea-import-db", "db", {
        "restartPolicy": "Always",
        "securityContext": {"runAsNonRoot": True, "runAsUser": 26, "runAsGroup": 26,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [c],
    })


def files_pod(dep, secret):
    t = dep["spec"]["template"]["spec"]
    c = json.loads(json.dumps(t["containers"][0]))
    for k in ("ports", "livenessProbe", "readinessProbe", "startupProbe", "lifecycle", "args"):
        c.pop(k, None)
    c["name"] = "gitea-import"
    c["command"] = ["sleep", "14400"]
    c["env"] = list(c.get("env", [])) + [
        secret_env("GITEA__DATABASE__USER", secret, "username"),
        secret_env("GITEA__DATABASE__PASSWD", secret, "password"),
    ]
    c["securityContext"] = dict(c.get("securityContext") or RESTRICTED)
    c["resources"] = {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"memory": "1Gi"}}
    used = {m["name"] for m in c.get("volumeMounts", [])}
    spec = {
        "securityContext": t.get("securityContext", {}),
        "containers": [c],
        "volumes": [v for v in t.get("volumes", []) if v["name"] in used],
    }
    return pod("gitea-import-files", "files", spec)


def main(a):
    if len(a) == 8 and a[1] == "db":
        out = db_pod(*a[2:8])
    elif len(a) == 3 and a[1] == "files":
        out = files_pod(json.load(sys.stdin), a[2])
    else:
        sys.stderr.write(__doc__)
        return 2
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
