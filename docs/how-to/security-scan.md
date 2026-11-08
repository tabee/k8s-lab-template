---
title: Sicherheitsprüfung (Geheimnisse, Personendaten, Konfiguration)
---

# Sicherheitsprüfung

`scripts/security-scan.sh` ist **die eine Stelle** für alle Sicherheits- und
Datenschutzprüfungen. GitHub Actions (`.github/workflows/security.yml`), Gitea Actions
(`.github/workflows/security.yml`), der pre-commit-Hook und der lokale Lauf rufen dieses
Skript auf. Warum diese Werkzeuge und welche Rechtsgrundlage dahintersteht, steht in
[Öffentliches Repo und Personendaten](../concepts/public-release-security.md).

## Schnellstart

Die Toolbox installiert `zizmor` in einer eigenen pipx-Umgebung. Die Version kommt
unverändert aus `ci/requirements-security.txt`; alle Downloads werden mit den dort
hinterlegten Hashes geprüft. Ist die passende Version vorhanden, bleibt sie unverändert.
Nur fehlende apt-Pakete benötigen sudo. `yamllint` und `shellcheck` bleiben über die
bestehende Lint-Sperrdatei abgedeckt; PyYAML kommt auf dem Steuer-PC aus `python3-yaml`.

```bash
bash scripts/install-security-tools.sh          # Werkzeuge nach ~/.local/bin (Version und SHA-256 festgenagelt)
bash scripts/install-tools.sh                   # zizmor aus der hash-geprüften Sicherheitssperrdatei
pip install --require-hashes -r ci/requirements-lint.txt       # yamllint, shellcheck und weitere Lint-Werkzeuge
export PATH="$HOME/.local/bin:$PATH"

bash scripts/security-scan.sh                   # alle Prüfungen, die hier gelten
bash scripts/security-scan.sh --list            # Prüfungen auflisten
bash scripts/security-scan.sh secrets lint      # nur einzelne Prüfungen
bash scripts/security-scan.sh --strict          # wie in der CI: ein fehlendes Werkzeug ist ein Fehler
```

## Die Prüfungen {#pruefungen}

| Prüfung | Werkzeug | Was sie findet |
|---|---|---|
| `secrets` | gitleaks, trufflehog (ohne Verifikation, kein Netz) | Passwörter, Tokens, Schlüssel im Arbeitsordner und in der Historie |
| `pii` | gitleaks mit `scripts/security/gitleaks-pii.toml` und der privaten Deny-Liste | AHV-Nummer, IBAN, Telefonnummer, E-Mail, Matrix-Kennung, Geburtsdatum, dazu alle Werte der Deny-Liste |
| `trivy` | trivy fs, Schwelle HIGH und CRITICAL | Geheimnisse, Fehlkonfiguration (Kubernetes, Helm, Dockerfile), verwundbare Abhängigkeiten |
| `kubeconform` | helm template und kubeconform, strikt | Manifeste, die nicht zum Schema der Kubernetes-Version passen |
| `actions` | actionlint, zizmor | Fehler und unsichere Muster in Workflow-Dateien |
| `lint` | yamllint, shellcheck | Stil und Fehler in YAML und Shell |
| `tree` | `scripts/security/check-public-tree.py` | Hosts, E-Mails und öffentliche IPs ausserhalb der Positivliste, SOPS-Chiffretexte, Schlüsseldateien |
| `identity` | `scripts/security/check-commit-identity.sh` | persönliche E-Mail-Adressen (Autor und Committer) in Commits; erlaubt sind nur noreply- und Platzhalter-Adressen. Namen prüft sie nicht |
| `export` | nur im privaten Repo | baut die öffentliche Fassung in einen temporären Ordner und führt **alle** Prüfungen darauf aus, mit der privaten Deny-Liste |

**Was im Arbeitsordner geprüft wird:** nur, was git committen würde, also versionierte Dateien
plus neue Dateien, die nicht ignoriert sind (`git ls-files -co --exclude-standard`). Ignorierte
Ordner wie `ansible/.ansible/` (installierte Galaxy-Collections), venvs und Caches sind
Fremdcode und ausserhalb des Umfangs. Das Skript legt dafür eine temporäre Kopie dieser
Dateien an und lässt gitleaks, trufflehog und trivy darauf laufen. Die Historie (`gitleaks git`,
`trufflehog git`) ist davon nicht betroffen.

Im privaten Repo laufen standardmässig `secrets`, `trivy`, `kubeconform`, `actions`,
`lint` und `export`. Die Personendaten-Prüfungen (`pii`, `tree`, `identity`) laufen dort
**auf der öffentlichen Fassung** innerhalb von `export`, weil das private Repo die echte
Domäne und Adresse absichtlich enthält. Im öffentlichen Baum laufen alle ausser `export`.

**Exit-Codes:** 0 alles grün, 1 mindestens eine Prüfung rot (gewinnt immer), 2 nichts
rot, aber ein Werkzeug fehlt (SKIP mit Installationshinweis, nie ein stilles Grün),
3 Aufrufsfehler. Mit `--strict` wird 2 zu 1.

## Einen Fund lesen {#fund}

Die Ausgabe zeigt **nie den Wert**, nur Prüfung, Regel, Datei und Zeile. Bei privaten
Regeln heisst die Regel anonym `pii-007`, und Pfade, die einen privaten Namen enthalten
würden, werden verborgen (`summarize.py`). Den Wert siehst du lokal mit `git show`
oder in der Datei, nie in einem Chat oder Issue.

Ist ein Fund **echt**:

1. **Rotieren:** neues Passwort oder Token, das alte beim Dienst widerrufen. Ab dem
   Push gilt es als bekannt.
2. **Personendaten:** sofort den Betreiber informieren. Ein Leck besonders schützenswerter
   Daten kann meldepflichtig sein (Art. 24 DSG; DSGVO Art. 33, 72 Stunden). Die Bewertung
   macht ein Mensch, nicht die CI.
3. Aus dem Code entfernen. Die Historie umschreiben nur nach Absprache; in einem
   **öffentlichen** Repo ersetzt das die Rotation nicht.

Ist es ein **Fehlalarm**: so eng wie möglich erlauben (nächster Abschnitt) und die Begründung
und das Datum als Kommentar daneben schreiben.

## Ausnahmen erlauben {#ausnahmen}

| Wofür | Wo | Form |
|---|---|---|
| gitleaks, ein Testwert | `.gitleaks.toml`, `[[allowlists]]` | `condition = "AND"` mit `paths`, `targetRules` und `regexes` (Pfad **und** Regel **und** Zeile) |
| trufflehog | `ci/trufflehog-exclude.txt` | ein regulärer Ausdruck für den Pfad pro Zeile, mit Begründung |
| trivy | `.trivyignore.yaml` | ein Eintrag mit `id`, `paths` und `statement` |
| Host oder E-Mail-Domäne im öffentlichen Baum | `scripts/security/allowed-hosts.txt` | ein Muster (`fnmatch`) pro Zeile; **nie** ein persönlicher Name |
| Export-Wächter | `scripts/public/allowed.txt` | `regel TAB pfad-glob TAB zeilen-regex` |
| Commit-E-Mail | `ALLOWED_COMMIT_EMAILS` (Umgebungsvariable) | ein ERE für die ganze Adresse, nur für Adressen, die der Betreiber bewusst öffentlich macht |

Kommentare wie `gitleaks:allow` wirken nicht (`--ignore-gitleaks-allow`).
`.gitleaksignore` gilt nur für den Scan im privaten Repo, **nicht** für die Prüfung der
öffentlichen Fassung, weil die Fingerabdrücke dort nicht stimmen. Für den Export gehört
eine Ausnahme darum in `.gitleaks.toml`.

## Die private Deny-Liste als CI-Secret {#deny-liste}

Die öffentliche CI kennt die echten Namen und Kennungen nicht, solange man sie ihr nicht
gibt. Dafür gibt es das Secret `PII_DENYLIST`:

- **Inhalt:** wie `scripts/public/denylist.txt`: pro Zeile `name TAB regex`, `#` und
  leere Zeilen werden übersprungen, ohne Gross-/Kleinschreibung.
- **Wo:** GitHub: Settings → Secrets and variables → Actions → Repository secret.
  Gitea: Repo-Einstellungen → Actions → Secrets. Nie als Variable und nie im Repo.
- **Was die CI daraus macht:** `pii-config.py` baut eine gitleaks-Konfiguration mit
  anonymen Regeln `pii-001`, `pii-002` und `pii-NNN-path` (Treffer im Dateinamen). Die
  Regel-IDs und Beschreibungen enthalten keinen Namen, und gitleaks läuft mit `--redact`.
- **Grenze:** Regeln mit Look-around (RE2 kennt keine) werden mit Warnung übersprungen.
  Sie müssen für das Secret ohne Look-around geschrieben werden. Der Export-Wächter im
  privaten Repo kennt sie weiterhin.
- **Fehlt das Secret** (zum Beispiel bei einem Pull Request aus einem Fork), läuft die
  Prüfung mit den generischen Regeln und meldet das; die Positivliste (`tree`) gilt immer.

Lokal im privaten Repo: `PII_DENYLIST_FILE=scripts/public/denylist.txt`. `export` setzt das selbst.

## pre-commit {#pre-commit}

```bash
pip install pre-commit                      # nicht in requirements-security.txt (nur lokal nötig)
pre-commit install                          # Hooks für commit und push
pre-commit run --all-files                  # alles einmal von Hand
```

`.pre-commit-config.yaml` hat nur lokale Hooks (keine Fremd-Repos, nichts zum
Festnageln): gitleaks auf den gestagten Änderungen, yamllint, shellcheck, actionlint.
Beim **Push** laufen zusätzlich die Baumprüfung samt Personendaten und die Prüfung der
Commit-Identität, im privaten Repo werden sie übersprungen. Ein Hook ist umgehbar (`--no-verify`),
darum gibt es die CI.

## Werkzeug-Versionen wechseln {#versionen}

Version und SHA-256 stehen in `ci/security-tools.env`, die Python-Werkzeuge mit Hashes in
`ci/requirements-security.txt`. Wechsel: neue Version und Prüfsumme dort eintragen,
`bash scripts/install-security-tools.sh` und `bash scripts/security-scan.sh`
laufen lassen, committen. `tests/pins-tests.sh` prüft, dass CI und Skript dieselben
Festlegungen benutzen. Das Container-Image der Workflows ist per Digest festgenagelt und steht
nur im Workflow.

## Workflows {#workflows}

Der Workflow `security.yml` läuft bei Push, Pull Request, von Hand und wöchentlich
(neue Schwachstellen erscheinen auch ohne Commit). Er benutzt **keine Fremd-Aktion**
(auch nicht `actions/checkout`): ein festgenageltes Image als Job-Container, `git fetch`
mit dem Token des Laufs und `permissions: contents: read`. Es gibt also nichts, was über
einen Tag nachträglich ausgetauscht werden könnte. Kommt später eine Aktion dazu, muss
sie per Commit-SHA festgenagelt sein; zizmor meldet es sonst.

Voraussetzungen: auf GitHub nichts. In Gitea muss Actions für das Repo eingeschaltet sein
und ein Runner mit Netz bereitstehen (trivy lädt seine Datenbank, die Werkzeuge
kommen beim Start des Jobs per `install-security-tools.sh`).

## Tests {#tests}

```bash
bash tests/security-scan-tests.sh     # Skript, Installer, Regeln, Positivliste, Identität
bash tests/public-tests.sh            # Export und Wächter (nur im privaten Repo)
bash tests/pins-tests.sh              # Festlegungen von Image, Werkzeugen, Workflow
bash scripts/ci-tests.sh              # alle Suiten; fehlende Werkzeuge sind SKIP mit Hinweis
```
