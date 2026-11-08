---
title: Werkzeuge des Steuerrechners
---

# Werkzeuge des Steuerrechners

**Was:** `lab.sh tools install` richtet die Werkzeuge für Aufbau und Betrieb auf einem
Ubuntu-24.04-Steuerrechner (amd64) ein. **Warum auf dem Host:** OpenTofu und Ansible
brauchen libvirt, sudo und die SSH-Schlüssel des angemeldeten Benutzers. Ein Container
würde diese Grenzen nur verschieben und den Neuaufbau nach einem Rechnerverlust erschweren.
Das Skript startet keine VM, aktiviert keine Firewall und verändert keine Schlüssel.

!!! tip "Eselsbrücke: erst die Werkbank, dann das Haus"
    `tools install` stellt die Werkbank bereit. `kit import` legt die Schlüssel zurück.
    Erst danach baut `up` das Haus. Eine Werkbank ersetzt weder Schlüssel noch Sicherungen.

## Anwenden

Nach dem Klonen, als normaler Benutzer, **nicht mit `sudo bash`**:

```bash
export PATH="$HOME/.local/bin:$PATH"
bash scripts/lab.sh tools check
bash scripts/lab.sh tools install
bash scripts/lab.sh tools install
bash scripts/lab.sh tools check
```

Die erste Prüfung darf fehlende Werkzeuge melden (Exit 1). Der zweite Installationslauf
muss `changes 0` und für jedes unveränderte Werkzeug `ok <tool> <version>` zeigen.
Nur fehlende apt-Pakete lösen `apt-get update` und `apt-get install` aus. Als normaler
Benutzer wird sudo einmal validiert; die apt-Aufrufe verwenden danach `sudo -n`.
Das Skript speichert kein Passwort und öffnet keinen zweiten Passwortdialog.
Die apt-Metadaten kommen aus den eingerichteten Ubuntu-Paketquellen, nicht aus einem
zusätzlichen Paket-Repository.

| Aufruf / Option | Verhalten |
|---|---|
| `tools check` oder direkt `install-tools.sh --check` | Nur lesen, kein sudo, keine Downloads, keine Verzeichnisse anlegen; Exit 1 bei fehlender oder falscher Version |
| `tools install --dry-run` | Plan ausgeben, ohne Änderungen; Exit 0 für einen gültigen Plan |
| `tools install --no-upgrade` | Fehlendes installieren; vorhandene abweichende Versionen nicht ersetzen und Exit 1 melden |
| `--skip-apt` | Nur Benutzerwerkzeuge; Teilprüfung für die Sandbox, kein Nachweis eines vollständigen Steuerrechners |
| `--skip-ansible` | Nur Release-Binaries und gegebenenfalls apt; ebenfalls nur eine Teilprüfung |

Direkter Einstieg: `bash scripts/install-tools.sh`. Rückgabewerte: 0 erfolgreich,
1 unvollständig oder Installationsfehler, 2 ungültiger Aufruf oder nicht unterstützte
Architektur. Ein Prüfsummenfehler bricht sofort ab; aus diesem Download wird nichts installiert.
Bereits zuvor erfolgreich installierte andere Werkzeuge bleiben erhalten.

## Umfang und Quellen

Die exakten Versionen stehen in `ci/control-tools.env`, die lesbare Tabelle in
[Versionen](versions.md). `tests/install-tools-tests.sh` vergleicht beide und prüft,
dass kubectl dieselbe Patchversion wie k3s hat. Der Helm-Pin wird auch vom Installer
der Sicherheitswerkzeuge gelesen, damit nicht zwei Soll-Versionen entstehen.

| Teil | Inhalt / Zweck |
|---|---|
| Release-Binaries in `~/.local/bin` | OpenTofu, kubectl, Helm v4, SOPS, age und age-keygen |
| Isoliertes Python über pipx | ansible-core ab 2.17 und die Python-Pakete `kubernetes` und `jsonpatch` in **demselben** Environment; exakte Pins in `ci/control-tools.env` |
| Python-Abhängigkeiten | `ci/requirements-control.txt`: transitive Abhängigkeiten mit SHA-256; pip lädt mit `--require-hashes`, pipx installiert ausschliesslich aus diesem geprüften lokalen Wheel-Verzeichnis |
| Galaxy | Alle Collections aus `ansible/requirements.yml`, einzeln auf Version geprüft und bei Abweichung ersetzt |
| apt | `ca-certificates`, `curl`, `openssl`, `openssh-client`, `git`, `gh`, `jq`, `unzip`, `tar`, `coreutils`, `gawk`, `python3`, `python3-venv`, `python3-yaml`, `pipx`, `qemu-system-x86`, `qemu-utils`, `libvirt-daemon-system`, `libvirt-clients`, `podman`, `ufw`, `uidmap`, `dbus-user-session`, `acl`, `rsync`, `gzip`, `util-linux` |
| Eigene Preflight-Werkzeuge | `LAB_TOOLS_EXTRA`: nur Vorhandensein prüfen, keine unbekannten Paketnamen erraten |

Die Release-Prüfsummen stammen aus den offiziellen Prüfsummendateien; die URL steht
jeweils als `*_SHA256_SOURCE` beim Pin. **Ausnahme age:** das Projekt veröffentlicht
Sigsum-Proofs statt einer SHA-256-Datei. Hier stammt der SHA-256 aus dem offiziellen
GitHub-Release-Asset (`digest`); der Download wird gegen diesen festgehaltenen Wert
geprüft. Der Installer behauptet keine Sigsum- oder Signaturprüfung.
Python-Paketversionen und Hashes im Lock entstehen aus den Python-Pins (einschliesslich pip für den pipx-Bootstrap):

```bash
source ci/control-tools.env
input=$(mktemp --suffix=.in)
printf 'ansible-core==%s\nkubernetes==%s\njsonpatch==%s\npip==%s\n' "$ANSIBLE_CORE_VERSION" "$KUBERNETES_PYTHON_VERSION" "$JSONPATCH_VERSION" "$PIP_VERSION" > "$input"
uv pip compile --generate-hashes --no-annotate --no-header --python-version 3.12 "$input" -o ci/requirements-control.txt
rm "$input"
bash tests/install-tools-tests.sh
```

apt-Pakete folgen Ubuntu-Sicherheitsupdates und werden nicht auf eine Release-Version
festgenagelt. Galaxy liefert hier keinen Hash-Lock; die Collections sind exakt auf
Version festgelegt. Optional bleiben die Argo-CD-CLI und `helm-diff`: sie sind für den
normalen Aufbau nicht nötig und werden nicht automatisch aus dem Netz ausgeführt.
Für manuelle Installation gelten die gleichen Pins und Prüfsummen; Ansible gehört
weiterhin in pipx, nicht in das Python von apt.

## Grenzen und nächste Schritte

Die Installation ist **keine Host-Konfiguration**: Gruppen `kvm`/`libvirt`, erneutes
Anmelden, libvirt-Netz und Speicherpool sowie eine aktive ufw-Firewall bleiben die
bewussten Schritte aus [Lab für Freunde](../tutorials/lab-for-friends.md#voraussetzungen).
Keine VM und kein anderer Rechner wird angefasst. Der Installer ändert `PATH` und
Shell-Startdateien nicht. Liegt ein anderes Programm vor `~/.local/bin` im `PATH`,
muss der Benutzer die Reihenfolge korrigieren. ARM64 ist nicht unterstützt; auch das
VM-Image des Labs ist auf amd64 festgelegt.

Zum Starten braucht es bereits eine Shell und einen Klon oder ein entpacktes Quellarchiv
(bei einem leeren PC zuerst den Zugang zu GitHub herstellen). Das ist die Bootstrap-Grenze,
nicht eine zusätzliche Liste von manuell zu installierenden Lab-Werkzeugen.
Sicherheits- und Doku-Entwicklungswerkzeuge bleiben in ihren eigenen Installationswegen:
[Security-Scan](../how-to/security-scan.md), [CI-Lint](../how-to/ci-lint.md), `docs/build.sh`.

Für einen echten Nachweis auf dem Steuerrechner die Ausgabe mit restriktiven Rechten sichern:

```bash
umask 077
mkdir -p ~/k8s-lab-data/logs
set -o pipefail
{
  bash scripts/lab.sh tools check || true
  bash scripts/lab.sh tools install &&
    bash scripts/lab.sh tools install &&
    bash scripts/lab.sh tools check
} 2>&1 | tee ~/k8s-lab-data/logs/tools-install.log
```

Ein Lauf mit ausgelassenem apt-Teil beweist Downloads und Benutzerwerkzeuge, aber weder
sudo noch libvirt/KVM oder die Betriebsbereitschaft des PCs. Dafür folgen `preflight`
und später die Abnahme auf dem vom Betreiber freigegebenen Rechner.
