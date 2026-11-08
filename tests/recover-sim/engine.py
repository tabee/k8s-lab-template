#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""A tiny in-memory cluster for tests/recover-sim-tests.sh (no Kubernetes, no Argo CD).

It knows only what ansible/recover-files.yml touches: Applications (root, gitea, matrix), Deployments, Pods and
PersistentVolumeClaims. Every API call is one tick. On every tick a controller step runs:

* an Application with automated sync that never succeeded starts a sync (at auto_start_tick)
* a sync operation (started by automated sync or by hand) ends after op_ticks ticks and then applies the
  Deployment with replicas 1, like Argo CD does, and marks the Application Synced
* a Deployment with replicas > desired gets pods that mount the claim, with fewer replicas it marks pods Terminating,
  and a Terminating pod disappears after term_ticks ticks (scale to zero returns BEFORE that, like k8s_scale)
* a PVC that is deleted while a pod mounts it stays Terminating (pvc-protection) until the last pod is gone

The state is one JSON file (SIM_STATE). `events` records what happened, so a test can assert on it.
CLI: engine.py init SCENARIO FILE | engine.py events FILE | engine.py get FILE KEY
"""
import copy
import json
import os
import sys

APPS = {
    "gitea": {"ns": "gitea", "deploy": "gitea", "claim": "gitea-shared-storage", "label": "gitea"},
    "matrix": {"ns": "matrix", "deploy": "synapse", "claim": "matrix-data", "label": "synapse"},
}
AUTOMATED = {"prune": True, "selfHeal": True}


def app_obj(name, automated, op=None, synced=False):
    spec = {"syncPolicy": {"syncOptions": ["ServerSideApply=true"], "retry": {"limit": 10}}}
    if automated:
        spec["syncPolicy"]["automated"] = dict(AUTOMATED)
    obj = {"metadata": {"name": name, "namespace": "argocd"}, "spec": spec, "status": {"sync": {"status": "Synced" if synced else "OutOfSync"}}}
    if synced:
        obj["status"]["operationState"] = {"phase": "Succeeded"}
    if op:
        obj["operation"] = {"initiatedBy": {"automated": True}, "sync": {}}
    return obj


def pod_obj(name, ns, label, claim, term=None):
    obj = {
        "metadata": {"name": name, "namespace": ns, "labels": {"app.kubernetes.io/name": label}},
        "spec": {"volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": claim}}, {"name": "tmp", "emptyDir": {}}]},
        "status": {"phase": "Running"},
    }
    if term is not None:
        obj["metadata"]["deletionTimestamp"] = "tick-%d" % term
    return obj


def init(scenario):
    s = {"tick": 0, "events": [], "term_ticks": 2, "scenario": scenario, "apps": {}, "deploys": {}, "pods": {}, "pvcs": {}, "opstart": {}, "op_ticks": {}, "auto_start": {}, "recreated": []}
    for name, a in APPS.items():
        s["pvcs"]["%s/%s" % (a["ns"], a["claim"])] = {"metadata": {"name": a["claim"], "namespace": a["ns"]}}
        s["op_ticks"][name] = 6
        s["auto_start"][name] = 0
    s["apps"]["root"] = app_obj("root", True, synced=True)
    for name in APPS:
        s["apps"][name] = app_obj(name, True, op=True)
        s["opstart"][name] = 0
    if scenario == "inflight":  # the real run: the first sync is running when the pause starts
        s["op_ticks"] = {"gitea": 14, "matrix": 14}
    elif scenario == "notstarted":  # the controller has not started the first sync yet
        for name in APPS:
            del s["apps"][name]["operation"]
            s["opstart"].pop(name)
            s["auto_start"][name] = 10 ** 6
    elif scenario == "synced":  # everything is synced and running before the pause
        for name, a in APPS.items():
            s["apps"][name] = app_obj(name, True, synced=True)
            s["opstart"].pop(name, None)
            make_deploy(s, name, 1)
    elif scenario in ("live", "terminating", "rogue", "unpaused"):  # restore only: paused apps, workload running
        for name, a in APPS.items():
            s["apps"][name] = app_obj(name, scenario == "unpaused", synced=True)
            s["apps"][name]["status"]["sync"]["status"] = "OutOfSync"
            s["opstart"].pop(name, None)
            make_deploy(s, name, 1)
        s["apps"]["root"] = app_obj("root", scenario == "unpaused", synced=True)
        if scenario == "terminating":
            s["pvcs"]["gitea/gitea-shared-storage"]["metadata"]["deletionTimestamp"] = "tick-0"
        if scenario == "rogue":
            s["pods"]["gitea/rogue"] = pod_obj("rogue", "gitea", "other", "gitea-shared-storage")
    else:
        raise SystemExit("unknown scenario %s" % scenario)
    return s


def make_deploy(s, app, replicas):
    a = APPS[app]
    s["deploys"]["%s/%s" % (a["ns"], a["deploy"])] = {"app": app, "replicas": replicas}
    reconcile(s)


def live_pods(s, ns, deploy_label=None):
    return [p for k, p in s["pods"].items() if p["metadata"]["namespace"] == ns]


def reconcile(s):
    for key, d in s["deploys"].items():
        a = APPS[d["app"]]
        mine = [(k, p) for k, p in s["pods"].items() if k.startswith(a["ns"] + "/" + a["deploy"] + "-")]
        active = [(k, p) for k, p in mine if "deletionTimestamp" not in p["metadata"]]
        for _ in range(d["replicas"] - len(active)):
            name = "%s-%d-%d" % (a["deploy"], s["tick"], len(mine))
            s["pods"]["%s/%s" % (a["ns"], name)] = pod_obj(name, a["ns"], a["label"], a["claim"])
            s["events"].append("pod %s/%s created while pvc %s mounted" % (a["ns"], name, a["claim"]))
            mine.append((None, None))
        for k, p in active[d["replicas"]:]:
            p["metadata"]["deletionTimestamp"] = "tick-%d" % s["tick"]


def step(s):
    s["tick"] += 1
    t = s["tick"]
    for name, a in APPS.items():
        app = s["apps"].get(name)
        if not app:
            continue
        auto = "automated" in app["spec"]["syncPolicy"]
        done = app.get("status", {}).get("operationState", {}).get("phase") == "Succeeded"
        if "operation" not in app and auto and not done and t >= s["auto_start"][name]:
            app["operation"] = {"initiatedBy": {"automated": True}, "sync": {}}
            s["opstart"][name] = t
        if "operation" in app and t - s["opstart"][name] >= s["op_ticks"][name]:
            del app["operation"]
            app["status"] = {"sync": {"status": "Synced"}, "operationState": {"phase": "Succeeded"}}
            if "%s/%s" % (a["ns"], a["deploy"]) not in s["deploys"]:
                s["deploys"]["%s/%s" % (a["ns"], a["deploy"])] = {"app": name, "replicas": 1}
                s["events"].append("sync of %s applied Deployment %s with replicas 1 (tick %d)" % (name, a["deploy"], t))
    reconcile(s)
    for k in [k for k, p in s["pods"].items() if "deletionTimestamp" in p["metadata"] and t - int(p["metadata"]["deletionTimestamp"].split("-")[1]) >= s["term_ticks"]]:
        del s["pods"][k]
    for k in [k for k, c in s["pvcs"].items() if "deletionTimestamp" in c["metadata"] and not mounted(s, k)]:
        del s["pvcs"][k]
        s["events"].append("pvc %s gone" % k)


def mounted(s, pvc_key):
    ns, claim = pvc_key.split("/")
    return [p["metadata"]["name"] for p in s["pods"].values() if p["metadata"]["namespace"] == ns
            and any(v.get("persistentVolumeClaim", {}).get("claimName") == claim for v in p["spec"]["volumes"])]


def load():
    with open(os.environ["SIM_STATE"]) as f:
        return json.load(f)


def save(s):
    with open(os.environ["SIM_STATE"], "w") as f:
        json.dump(s, f)


def delete_pvc(s, ns, name):
    key = "%s/%s" % (ns, name)
    if key not in s["pvcs"]:
        return
    if mounted(s, key):
        s["pvcs"][key]["metadata"].setdefault("deletionTimestamp", "tick-%d" % s["tick"])
        s["events"].append("pvc %s Terminating because %s mount it" % (key, ",".join(mounted(s, key))))
    else:
        del s["pvcs"][key]
        s["events"].append("pvc %s gone" % key)


def main():
    cmd = sys.argv[1]
    if cmd == "init":
        with open(sys.argv[3], "w") as f:
            if sys.argv[2].startswith("pl-"):
                import plugin_sim
                json.dump(plugin_sim.init(sys.argv[2]), f)
            else:
                json.dump(init(sys.argv[2]), f)
    elif cmd == "events":
        print("\n".join(json.load(open(sys.argv[2]))["events"]))
    elif cmd == "get":
        s = json.load(open(sys.argv[2]))
        for part in sys.argv[3].split("."):
            s = s[part]
        print(json.dumps(s))


if __name__ == "__main__":
    main()


def run_module(kind):
    """Entry point of the stub modules in collections/ (kubernetes.core.k8s_info, k8s, k8s_scale, k8s_json_patch; k8s_exec and k8s_log only exist so that the playbook parses)."""
    from ansible.module_utils.basic import AnsibleModule
    spec = {
        "k8s_info": dict(api_version={}, kind={}, namespace={}, name={}, label_selectors=dict(type="list", elements="str"), kubeconfig={}),
        "k8s_scale": dict(api_version={}, kind={}, namespace={}, name={}, replicas=dict(type="int"), wait=dict(type="bool"),
                          wait_timeout=dict(type="int"), kubeconfig={}),
        "k8s_json_patch": dict(api_version={}, kind={}, namespace={}, name={}, patch=dict(type="list", elements="dict"), kubeconfig={}),
        "k8s": dict(state={}, definition=dict(type="dict"), src=dict(type="path"), api_version={}, kind={}, namespace={}, name={},
                    wait=dict(type="bool"), wait_timeout=dict(type="int"), kubeconfig={},
                    label_selectors=dict(type="list", elements="str")),
        "k8s_exec": dict(namespace={}, pod={}, container={}, command={}, kubeconfig={}),
        "k8s_log": dict(api_version={}, kind={}, namespace={}, name={}, kubeconfig={}),
    }[kind]
    m = AnsibleModule(argument_spec=spec)
    p = m.params
    if kind in ("k8s_exec", "k8s_log"):
        m.fail_json(msg="sim: %s is not simulated" % kind)
    s = load()
    if s.get("model") == "plugin":
        import plugin_sim
        changed, out = plugin_sim.handle(s, kind, p, m)
        save(s)
        if "_fail" in out:
            m.fail_json(msg=out["_fail"])
        m.exit_json(changed=changed, **out)
    step(s)
    changed = False
    out = {}
    if kind == "k8s_info":
        out["resources"] = k8s_info(s, p)
    elif kind == "k8s_scale":
        key = "%s/%s" % (p["namespace"], p["name"])
        if key not in s["deploys"]:
            save(s)
            m.fail_json(msg="Failed to find exact match for apps/v1.Deployment by [kind, name, namespace, label_selectors] ... %s not found" % key)
        s["deploys"][key]["replicas"] = p["replicas"]
        s["events"].append("scale %s to %d" % (key, p["replicas"]))
        reconcile(s)
        changed = True
    elif kind == "k8s_json_patch":
        app = s["apps"][p["name"]]
        for op in p["patch"]:
            if op["path"] != "/spec/syncPolicy/automated":
                m.fail_json(msg="sim: unsupported patch path %s" % op["path"])
            if op["op"] == "remove":
                app["spec"]["syncPolicy"].pop("automated", None)
            else:
                app["spec"]["syncPolicy"]["automated"] = op.get("value")
        s["events"].append("patch %s %s" % (p["name"], op["op"]))
        changed = True
    else:
        changed = k8s_apply(s, p, m)
    save(s)
    m.exit_json(changed=changed, **out)


def k8s_info(s, p):
    k, ns, name = p["kind"], p["namespace"], p["name"]
    if k == "Application":
        res = [a for n, a in s["apps"].items() if not name or n == name]
    elif k == "Pod":
        res = [x for x in s["pods"].values() if x["metadata"]["namespace"] == ns and (not name or x["metadata"]["name"] == name)]
        for sel in p["label_selectors"] or []:
            lk, lv = sel.split("=", 1)
            res = [x for x in res if x["metadata"]["labels"].get(lk) == lv]
    elif k == "PersistentVolumeClaim":
        res = [c for key, c in s["pvcs"].items() if key.startswith(ns + "/") and (not name or c["metadata"]["name"] == name)]
    else:
        res = []
    return copy.deepcopy(res)


def k8s_apply(s, p, m):
    import yaml
    d = p["definition"]
    if p["src"]:
        with open(p["src"]) as f:
            d = yaml.safe_load(f)
    if p["state"] == "absent":
        if p["kind"] != "PersistentVolumeClaim":
            return False
        delete_pvc(s, p["namespace"], p["name"])
        if p["wait"]:
            key = "%s/%s" % (p["namespace"], p["name"])
            for _ in range(int((p["wait_timeout"] or 120) / 5)):
                if key not in s["pvcs"]:
                    break
                step(s)
            if key in s["pvcs"]:
                save(s)
                m.fail_json(msg="Failed to gather information about PersistentVolumeClaim(s) even after waiting for %s seconds" % p["wait_timeout"])
        return True
    if p["state"] == "patched":
        if d["kind"] == "Application" and "operation" in d:
            app = s["apps"][d["metadata"]["name"]]
            app["operation"] = d["operation"]
            s["opstart"][d["metadata"]["name"]] = s["tick"]
            s["events"].append("one-off sync of %s started: %s" % (d["metadata"]["name"], json.dumps(d["operation"], sort_keys=True)))
            return True
        m.fail_json(msg="sim: unsupported patch")
    if d["kind"] == "PersistentVolumeClaim":
        key = "%s/%s" % (d["metadata"]["namespace"], d["metadata"]["name"])
        s["pvcs"][key] = {"metadata": {"name": d["metadata"]["name"], "namespace": d["metadata"]["namespace"]}}
        s["events"].append("pvc %s recreated" % key)
        return True
    save(s)
    m.fail_json(msg="SIM-STOP at %s: the PVC is free and recreated, the rest of the restore is not simulated" % d["kind"])
