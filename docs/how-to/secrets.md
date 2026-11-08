---
title: Geheimnisse erzeugen und rotieren
---

# Geheimnisse erzeugen und rotieren

**Ziel:** alle Geheimnisse des Labs anlegen, ansehen (nie ihre Werte), ändern
und rotieren. Hintergrund: [Geheimnisfluss](../concepts/secret-flow.md);
die vollständige Liste: [Karte der Geheimnisse](../reference/secrets-map.md).

## Karte anzeigen

```bash
bash scripts/lab.sh secrets
```

Zeigt je Geheimnis Zweck, Pfad, Modus und ob die Datei vorhanden ist. **Nie
einen Wert.**

## Alles Fehlende anlegen

```bash
# preview only: what would be created, changed or restored
bash scripts/lab.sh init --dry-run
# do it
bash scripts/lab.sh init
```

`init` ist sicher mehrfach ausführbar:

| Meldung | Bedeutung |
|---|---|
| `SKIP` | Die Datei ist da und bleibt unangetastet (auch bei falschem Modus, nur mit Hinweis). |
| `ERZEUGT` | Neu angelegt (Modus 0600, Ordner 0700, Wert nicht angezeigt). |
| `WIEDERHERGESTELLT` | Lokale Datei fehlte, wurde aus der entschlüsselbaren SOPS-Datei im Git zurückgeholt. |
| `ABBRUCH` | Etwas passt nicht (zum Beispiel: dein age-Schlüssel ist kein Empfänger in `.sops.yaml`). Nichts wurde überschrieben. |
| `HINWEIS` | Information, zum Beispiel der öffentliche Teil eines neuen Deploy-Keys, den du im Git-Server als **nur lesenden** Schlüssel einträgst. |

Nur `--new-age-key` fasst die Empfänger in `.sops.yaml` an: Bereits
verschlüsselte Dateien für den alten Schlüssel bleiben dann unlesbar (`init`
meldet sie, löscht nie). Danach `git add secrets .sops.yaml`, committen,
pushen.

## Ein Secret im Cluster ändern

```bash
# opens the plaintext in $EDITOR (temp file mode 0600), SOPS re-encrypts
sops edit secrets/gitea/gitea-admin.sops.yaml
git add secrets && git commit -m "Gitea-Admin-Passwort rotieren" && git push origin main
```

Argo CD wendet es an, löscht aber nie ein Secret (`Prune=false`). Beachte die
Spalte „Rotation“ der Karte: Bei Datenbank-Passwörtern muss das Passwort
**zusätzlich in der Datenbank** gesetzt werden.

## Ein neues Secret anlegen

`ansible/scripts/sops-secret.sh` kennt fünf Unterbefehle:

```bash
# take an existing secret out of the cluster and store it encrypted
ansible/scripts/sops-secret.sh export NAMESPACE NAME

# from an env file (lines KEY=VALUE, mode 0600)
ansible/scripts/sops-secret.sh from-env NAMESPACE NAME ENVFILE

# from single values; KEY=@FILE reads a file (mode 0600, one line)
ansible/scripts/sops-secret.sh from-files NAMESPACE NAME TYPE KEY=@FILE

# compare hashes (never shows values)
ansible/scripts/sops-secret.sh hash-cluster NAMESPACE NAME
ansible/scripts/sops-secret.sh hash-datei secrets/NAMESPACE/NAME.sops.yaml
```

(`from-json` wird nur von `lab.sh init` benutzt.) Der Klartext geht nur durch
eine Pipe, nie auf die Platte. Ist das Ziel schon da: gleicher Inhalt = `SKIP`,
sonst `ABBRUCH`. Danach die Datei in `secrets/NAMESPACE/ksops.yaml` eintragen und
committen.

Soll das Secret mit `lab.sh init` reproduzierbar entstehen, gehört es in
`ansible/inventory/group_vars/all/secrets.yml` und braucht eine Vorlage
`secrets/NAMESPACE/NAME.sops.yaml.example`. Ein Test prüft, dass jeder Name der
Liste auf der [Karte](../reference/secrets-map.md) steht.

## age-Schlüssel rotieren {#age-schluessel-rotieren}

Reihenfolge so, dass zu jedem Zeitpunkt alles entschlüsselbar bleibt:

1. Neuen Schlüssel erzeugen und **zusätzlich** in `keys.txt` hängen (Modus
   bleibt 0600):

    ```bash
    age-keygen >> ~/.config/sops/age/keys.txt
    ```

2. Den neuen öffentlichen Schlüssel als zweiten Empfänger in `.sops.yaml`
   eintragen (`age: >-`, mit Komma getrennt). Wer das lieber von `init`
   erledigen lässt, nutzt `bash scripts/lab.sh init --new-age-key`
   (ersetzt den Empfänger; für eine Rotation mit zwei Empfängern von Hand).
3. Alle Dateien neu verschlüsseln:

    ```bash
    git ls-files 'secrets/*.sops.yaml' | xargs -n1 sops updatekeys -y
    ```

4. Commit, Push, dann `cd ansible && ansible-playbook argocd.yml` (das Secret
   `sops-age` hat jetzt beide Schlüssel; der `repo-server` sieht ihn nach
   etwa einer Minute ohne Neustart).
5. Alten Empfänger aus `.sops.yaml` entfernen, wieder `updatekeys`, Commit, Push.
6. Alten Schlüssel aus `keys.txt` entfernen, `argocd.yml` nochmals.
7. `ansible-playbook verify-ksops.yml`.

!!! warning "Alte Commits"
    Alte Commits bleiben mit dem alten Schlüssel lesbar. Ist der alte
    Schlüssel kompromittiert, müssen zusätzlich **die Secrets selbst** wechseln
    (zum Beispiel eine neue CA), nicht nur der Schlüssel.

## age-Schlüssel verloren {#age-schluessel-verloren}

Was im Cluster ist, läuft weiter: Argo CD löscht nichts (die App meldet nur
`ComparisonError`, die Secrets bleiben).

- **Rechner weg, Cluster da:** Der Schlüssel liegt im Secret `argocd/sops-age`.
  Zurückholen, ohne ihn anzuzeigen:

    ```bash
    ( set -euo pipefail; umask 077; mkdir -p ~/.config/sops/age
      test ! -e ~/.config/sops/age/keys.txt
      kubectl -n argocd get secret sops-age -o jsonpath='{.data.keys\.txt}' \
        | base64 -d > ~/.config/sops/age/keys.txt
      age-keygen -y ~/.config/sops/age/keys.txt )
    ```

- **Schlüssel ganz weg (Rechner und Cluster):** Die Dateien in `secrets/` sind
  nicht mehr lesbar. Solange die Secrets noch im Cluster sind: neuen Schlüssel
  erzeugen, in `.sops.yaml` eintragen, jede Datei mit
  `sops-secret.sh export NS NAME` neu aus dem Cluster erzeugen (vorher die alte
  Datei löschen), Commit, Push, `argocd.yml`.
- **Vorbeugen:** `keys.txt` offline sichern (Passwort-Manager oder gedruckter
  QR-Code). Ein zweiter, nur offline gehaltener Empfänger steht in
  [Issue 11](https://github.com/tabee/k8s-lab-template/issues/11).

## Einzelne Rotationen

Die Spalte „Rotation“ der [Karte](../reference/secrets-map.md) nennt den Weg je
Geheimnis. Grundregeln:

- **`k8up-repo-pw`**: nicht ohne neues restic-Repo rotierbar; alte Backups
  bleiben nur mit dem alten Passwort lesbar.
- **`vm-ssh-key`**: neues Paar bedeutet `rebuild`.
- **`lab-ca`**: [CA rotieren](ca-rotation.md).
- **S3-Zugänge**: Datei ersetzen, `backup-host.yml` (Benutzer neu registrieren),
  SOPS-Dateien neu rendern.

Das Argo-CD-Admin-Passwort ist nach jedem Neuaufbau neu
(`argocd-initial-admin-secret`); siehe [Argo CD bedienen](argocd-access.md).

## Getrenntes Secrets-Repo

Mit `secrets_repo_url` in `lab.yaml` liest Argo CD die Apps `secrets-*` aus einem eigenen privaten Repo. Nach
jeder Änderung in `secrets/` mit `bash scripts/lab.sh secrets-repo export DIR` spiegeln und dort pushen:
[Privates Secrets-Repo](private-secrets-repo.md).
