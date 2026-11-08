# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# CEL rules of the ValidatingAdmissionPolicy lab-ca-lab-domain-only checked with celpy (usage: python tests/ca-vap-cel-tests.py POLICY.yaml).
# celpy is only a test helper (pip install cel-python in a venv); the real API server is only checked on the VM.
import celpy, yaml, sys
path=sys.argv[1]
docs=list(yaml.safe_load_all(open(path)))
pol=docs[0]['spec']
env=celpy.Environment()
vars_={v['name']:v['expression'] for v in pol['variables']}
def inl(e):
    for k,v in vars_.items(): e=e.replace('variables.'+k,'('+v+')')
    return e
def ev(e,obj):
    return env.program(env.compile(inl(e))).evaluate({"object":celpy.json_to_cel(obj)})
def check(spec):
    obj={"spec":spec}
    if not ev(pol['matchConditions'][0]['expression'],obj): return "NOT-RESPONSIBLE"
    for v in pol['validations']:
        if not ev(v['expression'],obj): return "REJECTED: "+(ev(v['messageExpression'],obj) if 'messageExpression' in v else v['message'])
    return "ALLOWED"
F=0
def t(n,spec,exp):
    global F
    r=check(spec); ok=r.startswith(exp)
    print(("OK   " if ok else "FAIL ")+n+" -> "+r)
    if not ok: F+=1
ii={"name":"lab-ca","kind":"ClusterIssuer"}
t("inside",{"issuerRef":ii,"dnsNames":["a.lab.example"]},"ALLOWED")
t("zone itself",{"issuerRef":ii,"dnsNames":["lab.example"]},"ALLOWED")
t("wildcard",{"issuerRef":ii,"dnsNames":["*.lab.example"]},"ALLOWED")
t("outside",{"issuerRef":ii,"dnsNames":["a.example.org"]},"REJECTED")
t("suffix-trick",{"issuerRef":ii,"dnsNames":["evillab.example"]},"REJECTED")
t("mixed",{"issuerRef":ii,"dnsNames":["a.lab.example","x.example.org"]},"REJECTED")
t("cn outside",{"issuerRef":ii,"commonName":"x.example.org","dnsNames":["a.lab.example"]},"REJECTED")
t("cn inside",{"issuerRef":ii,"commonName":"a.lab.example","dnsNames":["a.lab.example"]},"ALLOWED")
t("only cn outside",{"issuerRef":ii,"commonName":"x.example.org"},"REJECTED")
t("ip",{"issuerRef":ii,"dnsNames":["a.lab.example"],"ipAddresses":["10.0.0.1"]},"REJECTED")
t("uri",{"issuerRef":ii,"dnsNames":["a.lab.example"],"uris":["spiffe://x"]},"REJECTED")
t("email",{"issuerRef":ii,"dnsNames":["a.lab.example"],"emailAddresses":["a@b"]},"REJECTED")
t("other issuer",{"issuerRef":{"name":"lab-acme"},"dnsNames":["x.example.org"]},"NOT-RESPONSIBLE")
t("no names",{"issuerRef":ii},"ALLOWED")
print("ERROR:",F); sys.exit(1 if F else 0)
