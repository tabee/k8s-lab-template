---
title: Versionen und Pins
---

# Referenz: Versionen und Pins

Alles, was das Lab von aussen holt, ist festgelegt. Die Spalte „Pin“ sagt, wie fest:
**Digest** (unveränderlich), **Version** (Release-Tag oder Chart-Version) oder
**Tag** (kann der Betreiber der Registry verschieben). Was nicht gepinnt ist,
steht am Ende ehrlich in einer eigenen Tabelle. Wie die Pins geprüft werden:
[CI-Prüfung](../how-to/ci-lint.md) und `scripts/pins-online.py --check` ([Issue 10](https://github.com/tabee/k8s-lab-template/issues/10)).

Die Werte stammen aus dem Repository (Dateiangabe je Zeile). Bei einer
Änderung ändern sich beide Seiten zusammen.

## Plattform

| Baustein | Wert | Pin | Wo |
|---|---|---|---|
| Basis-Image der VM | Ubuntu 24.04 (noble), `release-20261017` | Version + SHA-256 | `lab.yaml` (`image_url`, `image_sha256`, `image_file`) |
| k3s | `v1.36.5+k3s1` (Binär-SHA-256 je Architektur, `install.sh` aus demselben Git-Tag mit SHA-256) | Version + Hash | `group_vars/k3s/main.yml` |
| OpenTofu | `>= 1.8.0` (lokal); weitere Umgebungen mit S3-Zustand und Sperrdatei `>= 1.10.0` | Untergrenze | `infra/` (`required_version`) |
| Provider `dmacvicar/libvirt` | `0.9.9` | Version | `infra/` (Lock-Datei bleibt im Git) |
| Ansible-Collections | `ansible.posix` 2.2.2, `community.general` 13.5.0, `kubernetes.core` 6.6.0 | Version | `ansible/requirements.yml` |
| Pod-Netz / Service-Netz | `10.42.0.0/16` / `10.43.0.0/16` | explizit | `group_vars/k3s/main.yml` |


## Dienste im Cluster (Argo CD)

| Baustein | Chart | Image / Version | Pin | Wo |
|---|---|---|---|---|
| Argo CD | `argo-cd` 10.11.1 | vom Chart | Chart-Version | `group_vars/all/argocd.yml` (`argocd_chart_version`) |
| KSOPS (Sidecar) | | `quay.io/viaductoss/ksops:v4.5.1@sha256:…` | Digest | `group_vars/all/argocd.yml` (`argocd_ksops_image`) |
| Traefik | `traefik` 42.1.3 | `traefik:v3.7.16@sha256:…` (Standard des Charts per `versionOverride` und `image.digest` überschrieben) | Digest | `gitops/platform/traefik/values.yaml` |
| cert-manager | `cert-manager` v1.21.3 | vom Chart | Chart-Version | `gitops/apps/cert-manager.yaml` |
| CloudNativePG | `cloudnative-pg` 0.29.1 | Operator 1.30.1 | Chart-Version | `gitops/apps/cnpg.yaml` |
| Barman Cloud Plugin | `plugin-barman-cloud` 0.8.1 | Plugin 0.15.1 | Chart-Version | `gitops/apps/cnpg.yaml` |
| PostgreSQL (`pg-lab`, `gitea-db`, `matrix-db`, `keycloak-db`) | | `ghcr.io/cloudnative-pg/postgresql:18.6-minimal-trixie@sha256:…` | Digest | `gitops/workloads/db-lab/cluster.yaml` (Kopie in `gitops/workloads/matrix/manifests/cluster.yaml`) |
| Gitea | `gitea` 12.7.0 | `gitea` 1.27.3 (rootless) | Chart-Version + Tag | `gitops/apps/gitea.yaml`, `values-gitea.yaml` |
| Gitea Runner (Gitea Actions) | | `docker.io/gitea/runner:5.4.1@sha256:…` | Digest | `gitops/workloads/gitea-runner/deployment.yaml` |
| Python (Standard-Image der CI-Jobs, `ubuntu-latest`) | | `docker.io/library/python:3.13.17-trixie@sha256:…` | Digest | `gitops/workloads/gitea-runner/configmap.yaml` (Kopie von `.github/workflows/lint.yml`) |
| Keycloak | | `quay.io/keycloak/keycloak:26.8.1-2@sha256:…` | Digest | `gitops/workloads/keycloak/manifests/deployment.yaml` |
| keycloak-config-cli | | `quay.io/adorsys/keycloak-config-cli:6.5.1-26.5.5@sha256:…` | Digest | `gitops/workloads/keycloak/manifests/job-config.yaml` |
| oauth2-proxy (Login-Proxy der Notizseiten, `auth: sso`) | | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.5@sha256:…` | Digest | `gitops/charts/notes-site/values.yaml` (`images.proxy`) |
| Synapse | | `ghcr.io/element-hq/synapse:v1.164.1@sha256:…` | Digest | `gitops/charts/matrix/templates/deployment-synapse.yaml` |
| Element Web | | `ghcr.io/element-hq/element-web:v1.12.33@sha256:…` | Digest | `gitops/charts/matrix/templates/deployment-element.yaml` |
| K8up | `k8up` 4.10.1 | `k8up-io/k8up:v2.16.1@sha256:…` | Digest | `gitops/apps/k8up.yaml`, `gitops/platform/k8up/values.yaml` |
| whoami | | `traefik/whoami:v1.12.0@sha256:…` | Digest | `gitops/workloads/whoami/` |
| Doku-Build (Cluster) | | `python:3.13.17-trixie@sha256:…` | Digest | `gitops/workloads/docs/` |
| Doku-Auslieferung | | `joseluisq/static-web-server:2.44.1@sha256:…` | Digest | `gitops/workloads/docs/` |
| Prüf-Pods (Wegwerf-Pods in `verify-*.yml`, `psa-probe`, Rollen `docs_site`, `lab_ca`, `notes_sites`) | | `docker.io/library/busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec` | Digest | `group_vars/all/images.yml` (`lab_probe_image`, die einzige Stelle) |

## Steuerrechner

Werkzeuge für den Host: `bash scripts/lab.sh tools install`, Prüfung mit `tools check`.
Die [Werkzeug-Referenz](control-tools.md) erklärt Umfang und Grenzen. Die folgenden
Pins stammen aus `ci/control-tools.env`; die Offline-Suite prüft diese Kopie.

| Werkzeug | Version | Pin |
|---|---|---|
| OpenTofu | `1.13.9` | SHA-256 |
| kubectl (wie k3s) | `1.36.5` | SHA-256 |
| Helm | `4.3.1` | SHA-256, gemeinsam mit den Sicherheitswerkzeugen |
| SOPS | `3.13.3` | SHA-256 |
| age und age-keygen | `1.3.2` | SHA-256 (offizielle Release-Asset-Metadaten) |
| ansible-core | `2.19.15` | Wheel-SHA-256 und Python-Hash-Lock |
| Python-Paket kubernetes | `36.0.3` | Python-Hash-Lock |
| Python-Paket jsonpatch | `1.42` | Python-Hash-Lock; Voraussetzung von `kubernetes.core.k8s` |
| pip (pipx-Bootstrap) | `26.3` | Python-Hash-Lock |

apt-Pakete folgen den Ubuntu-Paketquellen und Sicherheitsupdates. Der Hash-Lock
für Python liegt in `ci/requirements-control.txt`, die Collections bleiben in
`ansible/requirements.yml` (exakte Versionen, kein Hash-Lock).

| Baustein | Wert | Pin | Wo |
|---|---|---|---|
| rustfs | `1.0.3@sha256:…` | Digest | `group_vars/all/backup_s3.yml` (`backup_s3_image`) |
| Podman (Mindestversion für Quadlet) | `4.5` | Untergrenze | `backup_s3_podman_min_version` |
| `curlimages/curl` (Prüfpod für `verify-backup-s3.yml`) | `8.17.0@sha256:…` | Digest | `backup_s3_verify_image` |
| gitleaks (CI und lokal) | `v8.30.1@sha256:…` | Digest | `.github/workflows/gitleaks.yml` (eine Zeile `image:`; `scripts/gitleaks-local.sh` liest sie dort) |

## Dokumentation

| Baustein | Wert | Pin | Wo |
|---|---|---|---|
| Zensical | `0.0.72` mit allen Abhängigkeiten per Hash (`pip --require-hashes`) | Version + Hash | `docs/requirements.txt` |
| Mermaid | `mermaid@11.17.2` (`MERMAID_VERSION`), selbst ausgeliefert unter `/assets/vendor/mermaid/mermaid-11.17.2.min.js`; Tarball per SHA-512 geprüft (`MERMAID_TGZ_SHA512`), im Browser per SRI-Hash (SHA-384) | Version + SHA-512 + SRI | `docs/build.sh`, `docs/vendor-mermaid.py`; [ADR-0010](../concepts/decisions/0010-mermaid-cdn.md) |

## Nicht auf Digest festgelegt

| Baustein | Stand |
|---|---|
| Images, die ein Chart selbst festlegt (Argo CD, cert-manager, CloudNativePG-Operator, Barman-Cloud-Plugin, Valkey/Redis) | folgen dem Chart; das Chart ist per Version gepinnt ([Sicherheitsmodell R9](../concepts/security-model.md)) |
| Ansible-Collections | nur Version, kein Hash (Galaxy liefert keinen) |
| Gitea-Image | Tag |
| Mermaid im Browser | Hauptversion `11` |
| Ubuntu-Pakete in der VM | `unattended-upgrades` (nur Sicherheitsupdates, kein automatischer Neustart, 03:30) |

!!! tip "Änderung eines Pins"
    Neues Basis-Image: alle drei Werte (`image_url`, `image_sha256`, `image_file`)
    zusammen ändern. Neue k3s-Version: Version und beide Hashes zusammen. Neue
    Zensical-Version: `docs/requirements.txt` mit `uv pip compile --generate-hashes`
    neu erzeugen (Befehl steht im Kopf der Datei).
