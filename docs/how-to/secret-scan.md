---
title: Secret-Scan (gitleaks)
---

# Secret-Scan mit gitleaks

Gitleaks sucht in der Git-Historie nach Passwörtern, Tokens und Schlüsseln, die
versehentlich eingecheckt wurden. Der Scan läuft als Gitea Action bei jedem Push
(alle Branches), bei jedem Pull Request und von Hand (`workflow_dispatch`). Ein Fund
macht den Lauf rot.

!!! info "Mehr als gitleaks"
    Dieser Scan ist ein Teil der [Sicherheitsprüfung](security-scan.md): Dort laufen zusätzlich
    trufflehog, Personendaten-Regeln, trivy, kubeconform und die Workflow-Prüfung, auch auf GitHub.

## Warum

Ein Secret in Git ist für immer in der Historie, auch wenn es im nächsten Commit
wieder verschwindet. Die Geheimnisse des Labs liegen darum nur als SOPS-Dateien
(`secrets/**/*.sops.yaml`, siehe [Stufe 7: Secrets (KSOPS)](../learning-path/stage-7-ksops.md) und [Secret-Fluss](../concepts/secret-flow.md)) im Repo.
Der Scan prüft, dass daneben nichts im Klartext landet.

## Was wo steht

| Datei | Inhalt |
| --- | --- |
| `.github/workflows/gitleaks.yml` | Workflow. Hier steht als einzige Stelle das gitleaks-Image mit Tag und Digest. |
| `.gitleaks.toml` | Konfiguration: Standardregeln von gitleaks, dazu enge Allowlists für zwei Testwerte (Pfad **und** Regel **und** Zeile). |
| `scripts/gitleaks-local.sh` | Derselbe Scan lokal (podman oder docker), gleiches Image, gleiche Optionen. |
| `.gitleaksignore` | Gibt es nur, wenn ein einzelner Fund bewusst erlaubt wurde (siehe unten). |

Der Workflow benutzt keine gitleaks-Action von GitHub und kein `actions/checkout`: Er
startet das gitleaks-Image als Job-Container, holt die ganze Historie mit `git fetch`
und ruft gitleaks direkt auf. Der Scan braucht das Gitea-Token des Laufs nur zum
Lesen (`permissions: contents: read`).

Voraussetzung in Gitea: Actions muss für das Repo eingeschaltet sein. Laut
Gitea-Doku sind Actions in einem Repo standardmässig aus, auch wenn sie auf der
Instanz laufen. Die Option heisst in den Repo-Einstellungen "Enable Repository
Actions" (Quelle: docs.gitea.com, Quick Start, Abschnitt "Use Actions").

!!! warning "gitleaks aus apt ist zu alt"
    Das Paket `gitleaks` aus den Ubuntu-Quellen (24.04 und 26.04, Version 8.16) kennt den Unterbefehl `dir` nicht, er kam mit
    Version 8.19. Die Prüfung der öffentlichen Fassung (`lab.sh guard`, `lab.sh export`) meldet dann «gitleaks too old» und
    überspringt die Zusatzprüfung; mit `--gitleaks-required` ist das ein Fehler, nie ein «Fund». Nimm `bash scripts/gitleaks-local.sh`
    (festes Image aus dem Workflow) oder das Binary ab Version 8.19 von github.com/gitleaks/gitleaks.

## Lokal ausführen

```bash
bash scripts/gitleaks-local.sh            # ganze Historie
bash scripts/gitleaks-local.sh --staged   # nur gestagte Aenderungen, vor dem Commit
```

Das Skript liest das Image aus dem Workflow, startet es mit podman (sonst docker) und
hängt das Repo nur lesend ein. Ein Hook ist optional: `pre-commit install` richtet ihn ein (siehe
[Sicherheitsprüfung](security-scan.md#pre-commit)), er ist umgehbar und ersetzt die CI nicht.
`gitleaks git` prüft nur Commits (und mit `--staged` den Index), keine Dateien, die
nur im Arbeitsordner liegen.

## Einen Fund lesen

Die Ausgabe zeigt nie den Wert (`--redact`). Wichtig sind diese Felder:

- `RuleID`: welche Regel angeschlagen hat (zum Beispiel `github-pat`, `aws-access-token`).
- `File` und `Line`: wo der Fund steht.
- `Commit`: in welchem Commit er zuerst eingecheckt wurde (nur beim Historie-Scan).
- `Fingerprint`: eindeutige Kennung des Funds (`Commit:Datei:Regel:Zeile`).

Den Wert siehst du mit `git show COMMIT:DATEI`. Das nur lokal tun und nirgends einfügen.

## Fund prüfen: echt oder Fehlalarm?

1. Ist der Wert ein echtes, gültiges Secret (Passwort, Token, privater Schlüssel)?
   Dann ist es ein echter Fund, siehe nächster Abschnitt.
2. Ist es ein Platzhalter, ein öffentlicher Wert (zum Beispiel ein Zertifikat oder ein
   öffentlicher Schlüssel) oder ein SOPS-verschlüsselter Wert? Dann ist es ein Fehlalarm.

### Fehlalarm erlauben

So eng wie möglich, in dieser Reihenfolge:

1. **Einzelner Fund in der Historie:** den `Fingerprint` in `.gitleaksignore` eintragen, eine Zeile pro
   Fund, mit einem Kommentar davor (warum, wann). Das erlaubt genau diesen einen Fund, aber nur im Scan
   des privaten Repos: Die Prüfung der öffentlichen Fassung scannt einen Ordner ohne Historie, dort greift die Datei nicht.
2. **Wiederkehrendes Muster, und alles, was auch im Export vorkommt:** in `.gitleaks.toml` einen `[[allowlists]]`-Block mit
   `condition = "AND"`, der Pfad (`paths`) und Regel (`targetRules`) verbindet, plus einem
   Kommentar mit Begründung. Nie eine Allowlist nur über den Pfad oder nur über ein
   breites Muster: So würde sie auch echte Funde in diesen Dateien verstecken.

Kommentare wie `gitleaks:allow` im Code wirken nicht, weil der Scan mit
`--ignore-gitleaks-allow` läuft. So stehen alle Ausnahmen an zwei Stellen, die im
Review auffallen.

Bei einem Fehlalarm in der Historie reicht der Eintrag in der Ignore-Datei. Die Historie
wird dafür nicht verändert.

Stand 2026-11-04 stehen fünf Fingerabdrücke in `.gitleaksignore`; die beiden Testwerte, die im aktuellen Stand noch vorkommen, sind zusätzlich als `[[allowlists]]` in `.gitleaks.toml` erlaubt. Es sind Testdaten:
zwei `curl -u`-Aufrufe im lokalen Import-Probelauf (`scripts/gitea-import-e2e.sh`,
Passwörter nur für `127.0.0.1`) und gepflanzte Token-Strings in älteren Ständen
von `tests/public-tests.sh` sowie derselben Suite unter ihrem früheren Dateinamen, in zwei Ständen.

## Echter Fund: Secret im Repo

1. **Secret sofort rotieren** (neues Passwort, Token neu ausstellen, Schlüssel
   tauschen) und das alte beim Dienst widerrufen. Das ist der wichtigste Schritt: Ab dem
   Push gilt das Secret als bekannt, auch wenn das Repo privat ist.
2. Neues Secret nur über SOPS ablegen ([Geheimnisse](secrets.md)).
3. Das Secret im Code entfernen (normaler Commit). Der Fund bleibt in der alten
   Historie und der Scan bleibt rot, bis das entschieden ist.
4. **Historie umschreiben (`git filter-repo`, Force-Push) nur nach Absprache.** Das
   ändert alle Commit-Hashes, betrifft alle Klone und Spiegel und ersetzt die Rotation
   nicht. Wenn das Secret rotiert und widerrufen ist, ist der Fund in der Historie
   ungefährlich und kann per Fingerabdruck erlaubt werden (siehe oben).

## Version wechseln

Nur in `.github/workflows/gitleaks.yml`, in der Zeile `image:`: Tag und Digest
zusammen ersetzen. Den Digest holt man mit `podman pull IMAGE:TAG` und
`podman image inspect --format '{{.Digest}}' IMAGE:TAG`. Danach
`bash scripts/gitleaks-local.sh` ausführen.

## Grenzen

- Gitleaks findet bekannte Muster und hohe Entropie, keine beliebigen Passwörter.
- SOPS-verschlüsselte Werte (`ENC[AES256_GCM,...]`) sind keine Funde.
- Dateien, die nie committet wurden (`secrets/` im Klartext ist per `.gitignore` ausgeschlossen),
  sieht der Scan nicht.
