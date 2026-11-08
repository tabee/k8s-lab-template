# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""In-memory model of what ansible/tasks/restore-plugin-ready.yml reads and changes (tests/recover-sim-tests.sh).

One tick per module call. Scenarios (prefix pl-) set when cert-manager, the Certificates and the plugin pod
come up and whether the cnpg Argo CD application needs a hand-made sync or the plugin pod needs a delete.
Nothing is real: no cluster, no network, no secret.
"""
import copy
import json

BASE = {
    "cm_up": 3,            # tick from which cert-manager's Deployments are Available (None: never)
    "crd_missing_until": 0,  # Certificate reads fail until this tick (CRD not installed yet)
    "certs_ready": 8,      # tick from which both Certificates are Ready (None: never)
    "needs_nudge": False,  # Certificates only appear after the Application got a sync operation
    "app_phase": "Succeeded",
    "dep_ready": 12,       # tick from which the plugin Deployment is Available
    "needs_pod_delete": False,  # the Deployment only becomes Available after the plugin pod was deleted
    "dead": False,         # never Available, whatever is done
}
SCENARIOS = {
    "pl-ok": {},
    "pl-slow": {"cm_up": 10, "crd_missing_until": 8, "certs_ready": 45, "dep_ready": 50},
    "pl-nudge": {"app_phase": "Failed", "needs_nudge": True, "certs_ready": 5},
    "pl-nudge-running": {"app_phase": "Running", "needs_nudge": True, "certs_ready": 5},
    "pl-stuckpod": {"certs_ready": 5, "needs_pod_delete": True},
    "pl-nocerts": {"certs_ready": None, "app_phase": "Running"},
    "pl-nocm": {"cm_up": None},
    "pl-dead": {"dead": True},
}


def init(scenario):
    if scenario not in SCENARIOS:
        raise SystemExit("unknown scenario %s" % scenario)
    cfg = dict(BASE)
    cfg.update(SCENARIOS[scenario])
    return {"model": "plugin", "tick": 0, "events": [], "cfg": cfg, "op": None, "op_tick": None, "pod_deleted": False}


def reached(s, tick):
    return tick is not None and s["tick"] >= tick


def certs_ready_now(s):
    c = s["cfg"]
    if c["needs_nudge"]:
        return s["op"] is not None and s["tick"] - s["op_tick"] >= c["certs_ready"]
    return reached(s, c["certs_ready"])


def cond(kind, status, reason="", message=""):
    return {"type": kind, "status": status, "reason": reason, "message": message}


def info(s, p):
    k, ns = p["kind"], p["namespace"]
    c = s["cfg"]
    sels = dict(x.split("=", 1) for x in (p.get("label_selectors") or []))
    if k == "Deployment" and ns == "cert-manager":
        up = reached(s, c["cm_up"])
        return [{"metadata": {"name": n, "namespace": ns}, "status": {"availableReplicas": 1 if up else 0}}
                for n in ("cert-manager", "cert-manager-webhook", "cert-manager-cainjector")]
    if k == "Deployment":
        ready = (not c["dead"]) and certs_ready_now(s) and reached(s, c["dep_ready"]) and (s["pod_deleted"] or not c["needs_pod_delete"])
        conds = [cond("Available", "True" if ready else "False"),
                 cond("Progressing", "True" if ready else "False", "NewReplicaSetAvailable" if ready else "ProgressDeadlineExceeded")]
        return [{"metadata": {"name": "plugin-barman-cloud", "namespace": ns}, "status": {"conditions": conds}}]
    if k == "Certificate":
        if s["tick"] < c["crd_missing_until"]:
            raise RuntimeError("Failed to find exact match for cert-manager.io/v1.Certificate by [kind, name, namespace, label_selectors]")
        if c["needs_nudge"] and s["op"] is None:
            return []
        ready = certs_ready_now(s)
        return [{"metadata": {"name": n, "namespace": ns},
                 "status": {"conditions": [cond("Ready", "True" if ready else "False", "Ready" if ready else "DoesNotExist", "waiting")]}}
                for n in ("barman-cloud-client", "barman-cloud-server")]
    if k == "Secret":
        return [{"metadata": {"name": p["name"], "namespace": ns}}] if certs_ready_now(s) else []
    if k == "Application":
        app = {"metadata": {"name": p["name"], "namespace": ns},
               "spec": {"syncPolicy": {"automated": {"prune": True, "selfHeal": True}, "syncOptions": ["ServerSideApply=true"], "retry": {"limit": 5}}},
               "status": {"sync": {"status": "OutOfSync"}, "operationState": {"phase": c["app_phase"], "message": "one or more objects failed to apply"}}}
        if s["op"] is not None:
            app["operation"] = s["op"]
        return [app]
    if k == "Pod":
        name = "plugin-barman-cloud-0" if sels.get("app.kubernetes.io/name") == "plugin-barman-cloud" else "cert-manager-0"
        return [{"metadata": {"name": name}, "status": {"phase": "Pending", "containerStatuses": [{"state": {"waiting": {"reason": "ContainerCreating"}}}]}}]
    if k == "EndpointSlice":
        return [{"metadata": {"name": "x"}, "endpoints": [{"conditions": {"ready": True}}]}]
    return []


def handle(s, kind, p, m):
    s["tick"] += 1
    if kind == "k8s_info":
        try:
            return False, {"resources": copy.deepcopy(info(s, p))}
        except RuntimeError as exc:
            return False, {"_fail": str(exc)}
    if kind == "k8s":
        d = p.get("definition") or {}
        if p["state"] == "patched" and d.get("kind") == "Application":
            s["op"], s["op_tick"] = d["operation"], s["tick"]
            s["events"].append("one-off sync of %s: %s" % (d["metadata"]["name"], json.dumps(d["operation"], sort_keys=True)))
            return True, {}
        if p["state"] == "absent" and p["kind"] == "Pod":
            s["pod_deleted"] = True
            s["events"].append("pod deleted by selector %s in %s" % (",".join(p.get("label_selectors") or []), p["namespace"]))
            return True, {}
    return False, {"_fail": "sim: not simulated: %s %s" % (kind, p)}
