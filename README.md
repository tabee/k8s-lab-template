# k8s-lab · vom leeren Ubuntu zum eigenen Lab

Eine VM, k3s, Argo CD, Gitea, Keycloak, Matrix und Doku – aus Git gebaut.

## Schnellstart

**Neues Lab:** Ubuntu 24.04 LTS, x86_64, VT-x/AMD-V im BIOS aktiv, mindestens 16 GiB RAM;
VM: 4 vCPU, 8 GiB RAM, 60 GB Disk. Mindestens 35 GiB frei im libvirt-Pool und 20 GiB für Exporte.
Internet, sudo und zwei **eigene leere private Repos** (Code und Secrets, gleicher SSH-Host und Port) vorbereiten;
dein persönlicher Git-Schreibzugang muss funktionieren. Nie in die öffentliche Vorlage zurückpushen.
**Bestehendes Lab retten?** Nicht neu initialisieren: [Notfall-Neuaufbau](docs/how-to/notfall-neuaufbau.md).

### 1 · Ubuntu und Quellen

Bash mit Fehlererkennung für Log-Pipelines starten; nach jedem Fehler stoppen und erst die Ursache beheben.

```bash
bash
set -o pipefail
```

Hardware prüfen: `/dev/kvm` muss existieren, Architektur muss `x86_64` sein.

```bash
uname -m && test -c /dev/kvm && lscpu && free -h && df -h "$HOME"
```

Log-Ordner anlegen und Git für den ersten Klon installieren.

```bash
mkdir -p ~/projects ~/k8s-lab-data/logs && sudo -v && sudo apt-get update && sudo apt-get install -y git ca-certificates
```

Vorlage klonen; die öffentliche Fassung verwendet das GitHub-Template, nicht den privaten Spiegel.

```bash
git clone https://github.com/tabee/k8s-lab-template.git ~/projects/k8s-lab-template && cd ~/projects/k8s-lab-template
```

Werkbank installieren: OpenTofu, Ansible samt Collections, kubectl, Helm, SOPS, age, Podman, libvirt und zizmor.

```bash
export PATH="$HOME/.local/bin:$PATH" && sudo -v && bash scripts/lab.sh tools install 2>&1 | tee ~/k8s-lab-data/logs/tools-$(date +%Y%m%d-%H%M%S).log
```

Scanner installieren, damit auch die spätere Security-Prüfung vollständig laufen kann.

```bash
bash scripts/install-security-tools.sh 2>&1 | tee ~/k8s-lab-data/logs/security-tools-$(date +%Y%m%d-%H%M%S).log
```


Im eigenen Arbeitsordner weiterarbeiten und die Werkzeug-Versionen prüfen.

```bash
cd ~/projects/k8s-lab-template && bash scripts/lab.sh tools check
```

### 2 · KVM, libvirt und Firewall

Den Benutzer für KVM/libvirt freischalten und libvirt starten; danach **abmelden und neu anmelden**.

```bash
sudo -v && sudo usermod -aG kvm,libvirt "$USER" && sudo systemctl enable --now libvirtd
```

Nach der Neuanmeldung Arbeitsordner, PATH und Fehlererkennung wieder setzen; beide Gruppen müssen erscheinen.

```bash
cd ~/projects/k8s-lab-template && export PATH="$HOME/.local/bin:$PATH" && set -o pipefail && id -nG
```

Das libvirt-Standardnetz aktivieren und beim Boot starten lassen.

```bash
virsh -c qemu:///system net-autostart default && { virsh -c qemu:///system net-list --name | grep -qx default || virsh -c qemu:///system net-start default; }
```

Fehlenden Standardpool anlegen; bestehenden Pool behalten.

```bash
if ! virsh -c qemu:///system pool-info default >/dev/null 2>&1; then
  virsh -c qemu:///system pool-define-as default dir --target /var/lib/libvirt/images && virsh -c qemu:///system pool-build default
fi
```

Den Standardpool starten und dauerhaft aktivieren.

```bash
virsh -c qemu:///system pool-autostart default && { virsh -c qemu:///system pool-list --name | grep -qx default || virsh -c qemu:///system pool-start default; }
```

Bei Fernzugriff zuerst den tatsächlichen SSH-Port freigeben (hier Standardport); danach ufw einschalten – rustfs braucht die aktive Firewall.

```bash
sudo -v && sudo ufw allow OpenSSH && sudo ufw enable && sudo ufw status
```

### 3 · Eigene Repos, eigene Werte

SSH-URLs deiner zwei privaten Repos einlesen; auch bei GitHub bleibt später `source: gitea` der direkte Repo-Modus, nicht der Spiegel-Modus.

```bash
read -r -p "SSH-URL Code-Repo: " CODE_REPO && read -r -p "SSH-URL Secrets-Repo: " SECRETS_REPO && export CODE_REPO SECRETS_REPO
```

Nur dein Code-Repo als Push-Ziel setzen; `main` und eine neutrale lokale Commit-Identität einrichten.

```bash
if git remote get-url origin >/dev/null 2>&1; then git remote remove origin; fi
git remote add origin "$CODE_REPO" && git branch -M main && git config user.name lab && git config user.email lab@example.org
```

Lokale Werte schreiben: eigene SSH-URLs, Lab-Domain `lab.example`, VM-Benutzer `lab` und eigener VM-Schlüssel; vorhandene Datei nicht überschreiben.

```bash
python3 - <<'PYCONFIG'
import os
from pathlib import Path
import yaml
values = dict(domain="lab.example", ssh_user="lab", ssh_key="~/.ssh/id_ed25519_lab",
              repo_url=os.environ["CODE_REPO"], secrets_repo_url=os.environ["SECRETS_REPO"], source="gitea")
with Path("infra/envs/local/lab.local.yaml").open("x") as stream:
    yaml.safe_dump(values, stream, sort_keys=False)
PYCONFIG
```

Domain, Repo-Adressen und Netzwerte nach GitOps übertragen.

```bash
bash scripts/lab.sh customize
```

Git-Host-Keys holen; Fingerabdrücke unabhängig beim Git-Host prüfen und erst dann mit `y` bestätigen.

```bash
bash scripts/lab.sh customize --fetch-host-keys
```

Die Git-Server-Adressen für die Egress-Regeln auflösen und eintragen.

```bash
bash scripts/lab.sh repo-egress --resolve
```

### 4 · Eigene Secrets statt fremder Schlüssel

age-Schlüssel, CA, Passwörter, VM-SSH-Schlüssel und zwei Deploy-Keys erzeugen; `init` erstellt `secrets/` aus `secrets.example/` und verschlüsselt selbst.

```bash
bash scripts/lab.sh init
```

Nur die **öffentlichen** Deploy-Keys anzeigen und beim jeweiligen Repo als **nur lesend** eintragen: Code-Key im Code-Repo, Secrets-Key im Secrets-Repo.

```bash
printf '%s\n' 'Code-Repo:' && cat ~/.ssh/argocd-k8s-lab.pub && printf '%s\n' 'Secrets-Repo:' && cat ~/.ssh/argocd-k8s-lab-secrets.pub
```

Die Geheimnis-Karte zeigt Pfade, nie Werte; age-Schlüssel, Lab-CA und restic-Passwort jetzt sicher ausserhalb des PCs sichern, niemals in Git oder Logs.

```bash
bash scripts/lab.sh secrets
```

Dein leeres privates Secrets-Repo neben dem Code klonen.

```bash
git clone "$SECRETS_REPO" ~/projects/k8s-lab-secrets && git -C ~/projects/k8s-lab-secrets switch -c main
```

Nur geprüften Ciphertext und KSOPS-Dateien ins Secrets-Repo exportieren.

```bash
bash scripts/lab.sh secrets-repo export ~/projects/k8s-lab-secrets
```

Privates Secrets-Repo prüfen, committen und pushen; nie Klartext oder private Schlüssel hinzufügen.

```bash
git -C ~/projects/k8s-lab-secrets config user.name lab && git -C ~/projects/k8s-lab-secrets config user.email lab@example.org && git -C ~/projects/k8s-lab-secrets add -A && git -C ~/projects/k8s-lab-secrets diff --cached --stat && git -C ~/projects/k8s-lab-secrets commit -m "Initialize encrypted lab secrets" && git -C ~/projects/k8s-lab-secrets push -u origin main
```

Nur Code-Konfiguration und öffentliche age-Empfänger ins **eigene private Code-Repo** pushen; `secrets/` bleibt dort ignoriert.

```bash
git add .sops.yaml gitops zensical.toml && git diff --cached --stat && git commit -m "Configure my lab" && git push -u origin main
```

### 5 · VM und Cluster hochziehen

Vorabprüfung ausführen; alles Rote beheben, bevor die VM gebaut wird.

```bash
bash scripts/lab.sh preflight 2>&1 | tee ~/k8s-lab-data/logs/preflight-$(date +%Y%m%d-%H%M%S).log
```

VM, k3s und alle Dienste mit einem Befehl bauen; sudo bleibt beim Benutzer, Ansible läuft **nicht** als root.

```bash
sudo -v && bash scripts/lab.sh up 2>&1 | tee ~/k8s-lab-data/logs/up-$(date +%Y%m%d-%H%M%S).log
```

Status und Kubernetes-Ressourcen prüfen.

```bash
bash scripts/lab.sh status && export KUBECONFIG="$HOME/.kube/k3s-lab.kubeconfig" && kubectl get nodes && kubectl get pods -A
```

Die Abnahme prüft auch Backup und Wiederherstellung mit Testdaten; erfolgreich ist erst `ACCEPTANCE PASSED`.

```bash
sudo -v && bash scripts/lab.sh acceptance 2>&1 | tee ~/k8s-lab-data/logs/acceptance-$(date +%Y%m%d-%H%M%S).log
```

### 6 · Browser auf

Nach `up` den Fingerabdruck der **öffentlichen** CA prüfen; Browser vorher einmal starten (Profil), dann vollständig schliessen.

```bash
openssl x509 -in ~/.config/k8s-lab/lab-ca.crt -noout -fingerprint -sha256
```

CA für System und Browser importieren; nur dieser eigenen Lab-CA vertrauen.

```bash
sudo -v && sudo apt-get install -y libnss3-tools && bash ansible/scripts/lab-ca-trust.sh add ~/.config/k8s-lab/lab-ca.crt
```

Adressen anzeigen und im Browser öffnen; `up` hat die Namen in `/etc/hosts` eingetragen (bei anderer Domain URLs anpassen).

```bash
printf '%s\n' https://docs.lab.example/ https://argocd.lab.example:8444/ https://git.lab.example/ https://sso.lab.example/realms/lab/account/ https://element.lab.example/ https://matrix.lab.example/_matrix/client/versions
```

Zugänge und sichere Abrufwege stehen in der [Geheimnis-Karte](docs/reference/secrets-map.md), Argo CD unter [Zugriff](docs/how-to/argocd-access.md).

Keycloak-Verwaltung in einem **zweiten Terminal** freigeben, dann `http://localhost:8080/admin/master/console/` öffnen; Benutzer im Realm `lab` der Gruppe `lab-users` zuweisen ([SSO](docs/how-to/keycloak.md)).

```bash
export KUBECONFIG="$HOME/.kube/k3s-lab.kubeconfig" && kubectl -n keycloak port-forward svc/keycloak 8080:8080
```

### 7 · Tests und Alltag

Testwerkzeuge mit den festgelegten Hashes isoliert installieren; ShellCheck kommt aus Ubuntu.

```bash
sudo -v && sudo apt-get install -y shellcheck && python3 -m venv ~/.local/share/k8s-lab-lint && ~/.local/share/k8s-lab-lint/bin/pip install --require-hashes -r ci/requirements-lint.txt && export PATH="$HOME/.local/bin:$HOME/.local/share/k8s-lab-lint/bin:$PATH"
```

Offline-Suites ausführen; `SKIP` ist kein Nachweis für die übersprungene Prüfung.

```bash
bash scripts/ci-tests.sh 2>&1 | tee ~/k8s-lab-data/logs/tests-$(date +%Y%m%d-%H%M%S).log
```

YAML, Shell und Ansible linten.

```bash
bash scripts/ci-lint.sh 2>&1 | tee ~/k8s-lab-data/logs/lint-$(date +%Y%m%d-%H%M%S).log
```

Eigenes privates Lab auf Secrets, Infrastruktur und Workflows prüfen; die öffentliche Baumprüfung gilt nur für die unveränderte Vorlage, nicht für deine persönlichen Werte.

```bash
bash scripts/security-scan.sh --strict secrets trivy kubeconform actions lint 2>&1 | tee ~/k8s-lab-data/logs/security-$(date +%Y%m%d-%H%M%S).log
```

Frische Datenbank- und Dateibackups erstellen und deren WAL-Abdeckung prüfen.

```bash
bash scripts/lab.sh backup 2>&1 | tee ~/k8s-lab-data/logs/backup-$(date +%Y%m%d-%H%M%S).log
```

Vor jedem Abbau die VM exportieren; sie fährt dafür kurz herunter und wieder hoch.

```bash
sudo -v && bash scripts/lab.sh export 2>&1 | tee ~/k8s-lab-data/logs/export-$(date +%Y%m%d-%H%M%S).log
```

**Optional, zerstörerisch:** VM samt Platte abbauen; rustfs-Backups und lokale Schlüssel bleiben erhalten.

```bash
bash scripts/lab.sh down
```

**Alternative zum Abbau:** mit frischem Export neu bauen **und Daten zurückholen**; beide Sicherheitsrückfragen beantworten, nie einfach `rebuild` nehmen (leert den Postgres-Bucket).

```bash
sudo -v && bash scripts/lab.sh rebuild --restore 2>&1 | tee ~/k8s-lab-data/logs/restore-$(date +%Y%m%d-%H%M%S).log
```

## Weiter

[Schritt für Schritt](docs/tutorials/lab-for-friends.md) · [Betrieb](docs/how-to/rebuild.md) ·
[Secrets-Repo](docs/how-to/private-secrets-repo.md) · [Doku](docs/index.md) · [Sicherheitsmodell](docs/concepts/security-model.md).

Lern- und Testlab, kein fertiges Produkt. Lizenz: **AGPL-3.0-only**.
Sicherheitsprobleme privat melden; Meldeweg und Lizenztext stehen in der öffentlichen Fassung unter `SECURITY.md` und `LICENSE`, Mitarbeit unter `CONTRIBUTING.md`.
