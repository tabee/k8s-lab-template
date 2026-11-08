---
title: Referenz Notfall-Kit
---

# Referenz: `lab.sh kit` (Notfall-Kit)

`lab.sh kit` packt alle Dateien, die **nur auf dem Steuerrechner** liegen und die man zum Neuaufbau und zur
Wiederherstellung braucht, in **ein** verschlüsseltes Archiv auf einen USB-Stick, prüft es und legt es zurück.
Der Ablauf im Ernstfall steht in [Notfall-Neuaufbau](../how-to/notfall-neuaufbau.md), die Begründung in
[ADR-0025](../concepts/decisions/0025-emergency-kit.md). Das Skript heisst `scripts/emergency-kit.sh`; `lab.sh kit ...`
ruft es auf (beide Wege sind gleich).

```bash
bash scripts/lab.sh kit export DIR [--must-only] [--allow-missing]
bash scripts/lab.sh kit verify DIR
bash scripts/lab.sh kit import DIR [--force] [--dry-run] [--repo KLON]
```

**Eselsbrücke:** *Export = Koffer packen, Verify = Koffer wiegen und nachzählen, Import = Koffer auspacken, jedes Stück
an seinen Platz.*

## Befehle

| Befehl | Zweck | Ändert etwas? |
|---|---|---|
| `export DIR` | alle Dateien der Tabelle unten in `DIR/k8s-lab-kit.tar.age` (age, Passphrase), dazu Manifest und `README-NOTFALL.txt` | schreibt nur in `DIR` |
| `verify DIR` | entschlüsselt in ein 0700-tmpfs, vergleicht jede Datei mit dem Manifest | nein |
| `import DIR` | prüft wie `verify`, legt dann jede Datei an ihren ursprünglichen Pfad | schreibt Dateien unter `$HOME` und im Klon |

### Optionen

| Option | Gilt für | Wirkung |
|---|---|---|
| `--must-only` | `export` | nur die Pflichtdateien, ohne die bequemen |
| `--allow-missing` | `export` | schreibt auch bei fehlenden Pflichtdateien und vermerkt es im Manifest (`verify` und `import` warnen mit `INCOMPLETE KIT`) |
| `--force` | `import` | überschreibt eine vorhandene, andere Datei; die alte bleibt als `DATEI.before-kit-ZEIT` (0600) |
| `--dry-run` | `import` | zeigt den Plan (`SAME`, `NEW`, `DIFFERS`), schreibt nichts |
| `--repo KLON` | `import` | Ordner des Klons für Dateien im Repo (Standard: das Repo, in dem das Skript liegt) |

`$HOME` ist immer das Home-Verzeichnis des Aufrufers. `LAB_KIT_REPO` überschreibt den Repo-Ordner (nur für Tests).

### Rückgabewerte

| Wert | Bedeutung |
|---|---|
| 0 | gelungen; bei `verify` stimmt jede Datei |
| 1 | Abbruch (`ABORT`) oder Prüfung ohne Erfolg: fehlende Pflichtdatei, Ziel nicht schreibbar oder im Repo, falsche Passphrase, abweichende Datei, `import` ohne `--force` bei Konflikt |
| 2 | falsche Anwendung (Hilfe wird gezeigt) |

## Was `export` verweigert

- `DIR` ist kein Ordner oder nicht schreibbar.
- `DIR` liegt **im Repo** oder in irgendeinem Git-Arbeitsbaum (ein Kit gehört nie in Git).
- kein Terminal (`age -p` liest die Passphrase nur vom Terminal; es gibt keinen Weg, sie in einer Variablen oder einer
  Datei zu übergeben).
- eine Pflichtdatei fehlt (ohne `--allow-missing`): der Befehl listet sie alle und schreibt **nichts**.

Liegt `DIR` auf demselben Datenträger wie `$HOME`, **warnt** er: das wäre kein Stick, sondern eine zweite Kopie auf
derselben Platte.

## Die Dateien auf dem Stick

| Datei | Verschlüsselt | Inhalt |
|---|---|---|
| `k8s-lab-kit.tar.age` | ja (age, Passphrase) | die Dateien mit Pfad und Rechten, dazu eine Kopie des Manifests |
| `k8s-lab-kit.manifest` | nein | Kopfzeilen (Erstellzeit, Anker, GitHub-Adresse, `archive-sha256`) und je Datei eine Zeile `F` mit Klasse, Pflicht, Wurzel (`home` oder `repo`), Rechte, Grösse, SHA-256 und Pfad. **Nie ein Inhalt.** |
| `README-NOTFALL.txt` | nein | die Kurzfassung der Wiederherstellung auf Deutsch, mit der GitHub-Adresse und dem Vertrauensanker |

`verify` und `import` vergleichen das Manifest auf dem Stick mit dem Manifest **im** Archiv. Weichen sie ab, brechen sie
ab. Entschlüsselt wird nur in ein tmpfs (`XDG_RUNTIME_DIR`, `/dev/shm` oder `/run/user/UID`) mit Modus 0700; beim Beenden
werden die Dateien dort überschrieben (`shred`) und entfernt. Es liegt nie Klartext auf der Platte.

## Was im Kit liegt {#was-im-kit-liegt}

**Pflicht** (Klasse `must`): lässt sich **nicht** neu erzeugen, oder ein neuer Wert würde die Sicherungen unlesbar machen.
Zu jeder Datei steht die Wirkung des Verlusts. Pfade sind relativ zu `$HOME`, sofern nicht `Repo` dasteht.

**Fehlt = Fehler** (Spalte «Pflicht» = ja): `export` bricht ohne `--allow-missing` ab. Bei «nein» ist die Datei
Pflicht, wenn es sie gibt, aber nicht jedes Lab hat sie (zum Beispiel ohne Matrix).

| Name | Pfad | Pflicht | Was ohne sie passiert |
|---|---|---|---|
| `age-key` | `.config/sops/age/keys.txt` | ja | alle `*.sops.yaml` und alle verschlüsselten Dumps unlesbar. **Das einzige Stück, das es nirgends sonst gibt.** |
| `trust-anchor` | `.config/k8s-lab/trusted-head` | ja | `preflight` verlangt einen neuen Anker von Hand ([Quellvertrauen](../concepts/source-trust.md)) |
| `lab-local` | Repo: `infra/envs/local/lab.local.yaml` | ja | `source: github` und lokale Werte weg; ein Klon aus GitHub liest dann Gitea |
| `rustfs-root` | `.config/rustfs/rustfs.env` | ja | Zugang zum Backup-Ziel weg; neuer Root heisst neue, leere Buckets |
| `s3-cnpg`, `s3-k8up` | `.config/k8s-lab/s3-cnpg-k3s-lab.env`, `s3-k8up-k3s-lab.env` | ja | CNPG und K8up erreichen ihre Buckets nicht |
| `k8up-repo-pw` | `.config/k8s-lab/k8up-k3s-lab-repo.pw` | ja | das restic-Repository der Dateisicherungen ist **unlesbar** |
| `gitea-db-pw`, `gitea-admin-user`, `gitea-admin-pw` | `.config/k8s-lab/gitea-k3s-lab-*` | ja | wiederhergestellte Datenbank passt nicht zu den neuen Zugangsdaten |
| `matrix-db-pw`, `matrix-admin-user`, `matrix-admin-pw`, `matrix-registration-secret` | `.config/k8s-lab/matrix-k3s-lab-*` | ja | wie Gitea |
| `keycloak-db-pw`, `keycloak-admin-user`, `keycloak-admin-pw` | `.config/k8s-lab/keycloak-k3s-lab-*` | ja | wie Gitea |
| `keycloak-gitea-client-secret`, `keycloak-synapse-client-secret`, `keycloak-notes-client-secret` | `.config/k8s-lab/keycloak-k3s-lab-*-client.secret` | ja | Anmeldung per SSO bricht, bis alle drei Seiten neu abgeglichen sind |
| `break-glass-key` | `.config/k8s-lab/break-glass-age.txt` | nein | der Offline-Schlüssel als zweiter Empfänger der SOPS-Dateien: der Ersatz, wenn `age-key` fehlt ([Geheimnis-Karte](secrets-map.md)) |
| `matrix-signing-key` | `.config/k8s-lab/matrix-k3s-lab-signing.key` | nein | die Identität des Matrix-Servers: neuer Schlüssel heisst, dass die Gegenstellen dem Server nicht mehr trauen |
| `lab-ca` | `.config/k8s-lab/lab-ca-secret.yaml` | nein | neue CA, alle Browser und Clients müssen neu vertrauen |
| `signing-key` | `.ssh/k8s-lab-signing` | nein | Commits können nicht mehr signiert werden ([Signierte Commits](../how-to/signed-commits.md)) |
| `replica-install-key` | `.ssh/id_ed25519` | nein | die Einrichtung des Replikat-Rechners (`lab.sh replica install`) |
| `wireguard-server-key`, `wireguard-client-key` | `.config/k8s-lab/wireguard-server.key`, `wireguard-client.key` | nein | VPN-Identitäten weg; neue Schlüssel müssen auf beiden Gegenstellen abgeglichen werden |

**Bequem** (Klasse `nice`): lässt sich mit `lab.sh init` oder den Playbooks neu erzeugen, kostet aber Arbeit
(neuer Deploy-Key bei GitHub und Gitea eintragen, Replikat neu einrichten). `--must-only` lässt sie weg.

| Name | Pfad |
|---|---|
| `signing-key-pub`, `replica-install-key-pub` | `.ssh/k8s-lab-signing.pub`, `.ssh/id_ed25519.pub` |
| `lab-ca-cert` | `.config/k8s-lab/lab-ca.crt` |
| `argocd-deploy-key` (+ `.pub`) | `.ssh/argocd-k8s-lab` (Deploy-Key für das Repo) |
| `argocd-secrets-deploy-key` (+ `.pub`) | `.ssh/argocd-k8s-lab-secrets` (getrenntes Secrets-Repo, [ADR-0022](../concepts/decisions/0022-private-secrets-repo.md)) |
| `replica-ssh-key` (+ `.pub`) | `.ssh/k8s-lab-replica` |
| `vm-ssh-key` (+ `.pub`) | der Pfad `ssh_key` aus `lab.yaml` |
| `replica-known-hosts`, `replica-config` | `.config/k8s-lab/replica_known_hosts`, `replica.json` |
| `alert-config`, `alert-matrix-token` | `.config/k8s-lab/alert.json`, `alert-matrix.sops.yaml` |
| `alert-heartbeat-url` | `.config/k8s-lab/alert-heartbeat.sops.yaml` |
| `acme-token` | `.config/k8s-lab/acme-dns01.token` |
| `gitea-runner-token` | `.config/k8s-lab/gitea-k3s-lab-runner.token` (Runner von [Gitea Actions](../how-to/gitea-actions.md)) |
| `notes-deploy-keys` | `.ssh/notes-*-deploy*` |
| `notes-passwords`, `notes-cookies` | `.config/k8s-lab/notes-*.passwort`, `notes-*.cookie` |
| `kit-extra-list` | `.config/k8s-lab/kit-extra.list` |

**Nicht im Kit**, weil abgeleitet: die Kubeconfig (`lab.sh up` legt sie neu an) und das Argo-CD-Admin-Passwort. **Nicht im
Kit**, weil es Daten sind und keine Schlüssel: die Sicherungen (`~/k8s-lab-data/backups`, Kopie auf dem Replikat-Rechner)
und die VM-Exporte.

Die Namen und Pfade der Pflichtdateien stehen als Tabelle in `scripts/emergency-kit.sh` (`kit_table`). Ein Test
(`tests/kit-tests.sh`) vergleicht sie mit `ansible/inventory/group_vars/all/secrets.yml`: kommt ein Geheimnis dazu, das
im Kit fehlt, schlägt er fehl.

## Eigene Zusätze: `kit-extra.list` {#kit-extra}

Zugänge, die dieses Repo nicht kennt (der Schlüssel zum alten Server, eine VPN-Datei), trägst du selbst ein. Die Datei
`~/.config/k8s-lab/kit-extra.list` hat **einen Pfad pro Zeile**, relativ zu `$HOME`, `*` als Platzhalter ist erlaubt und
`#` beginnt einen Kommentar:

```text
# Zugang zum alten Server
.ssh/id_ed25519_vps
.config/vpn/*.conf
```

Zusätze zählen zu den bequemen Dateien: eine fehlende Datei ist kein Fehler (`export` schreibt sie nicht), und
`--must-only` lässt sie weg. Pfade mit `..`, absolute Pfade und ungewöhnliche Zeichen werden mit einer Warnung
übersprungen. Doppelte Einträge zählen einmal.

## Rechte nach `import`

Verzeichnisse, die der Import anlegt, haben Modus 0700 (unter `$HOME`). Jede Datei mit Schlüssel oder Passwort
bekommt 0600. Öffentliche Dateien (`*.pub`, `lab-ca.crt`) behalten den Modus aus dem Manifest. Vorhandene
Verzeichnisse bleiben unverändert.

## Siehe auch

- [Notfall-Neuaufbau](../how-to/notfall-neuaufbau.md): der Ablauf vom Wegstellen bis zur Wiederherstellung.
- [Geheimnis-Karte](secrets-map.md): welche Geheimnisse es gibt und wer sie erzeugt.
- [Referenz `lab.sh`](lab-sh.md#kit-befehl)
