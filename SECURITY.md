# Security Policy

k8s-lab is a private learning project made public: a k3s lab on one machine (VM, Argo CD,
cert-manager with its own CA, SOPS/KSOPS, CloudNativePG, Gitea). It is meant for learning and
rebuilding, **not** a hardened product, and there is no commercial support or service level.
The documentation is in German; the threat model is `docs/concepts/security-model.md`
(known findings that are not a bug: R1 to R21 there).

## Supported versions

Only the current `main` branch gets fixes. There are no release branches and no back-ports.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Use GitHub's private vulnerability reporting:
[Report a vulnerability](https://github.com/tabee/k8s-lab-template/security/advisories/new)
("Security" tab of this repository). Write what you found, how to reproduce it, and which
commit you looked at. English or German is fine.

What to expect (best effort, one maintainer, no guarantee):

- an answer within 7 days that says whether the report is understood,
- a fix or a documented decision within 30 days for confirmed findings,
- credit in the changelog if you want it.

## In scope

- Scripts, Ansible roles, Helm charts and manifests in this repository: a flaw that leaks a
  secret, widens network access, weakens signing or the CA, or runs unexpected code.
- The export (`git archive` plus replacements) leaking private values: real domains, keys, tokens.
- Pins and supply chain: a wrong digest, a missing hash, an unpinned download.

## Out of scope

- Your own deployment (your domain, your keys, your router): harden it yourself; the docs say how.
- Findings that are already named as accepted risks in `docs/concepts/security-model.md`.
- Denial of service against a lab VM, missing features, and reports without a way to reproduce.

## If you find a real secret in the repository

The repository must only contain `*.sops.yaml.example` templates, never real secrets. If you find
what looks like a real key, token or password, report it privately as above, and do not use it.

## Hinweis auf Deutsch

Bitte melde Sicherheitsprobleme **nicht** als öffentliches Issue, sondern über die private
Meldung oben (Reiter «Security», «Report a vulnerability»). Das Lab ist ein Übungsprojekt: Es gibt
keine Zusage für Reaktionszeiten, die Fristen oben sind ein Richtwert. Deutsch oder Englisch ist
beides in Ordnung.
