#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Language test for issue #13 ("code in English"). Everything in code is English: identifiers, comments,
# messages, test names, file names. German is allowed only where it is the product itself:
#   - .md files and docs/ (de-CH, user-facing),
#   - zensical.toml and scripts/public/replacements.tsv (texts of the German docs),
#   - the deprecated lab.sh aliases (removed before December 2026),
#   - a few documented names that exist outside git (see ALLOW_TEXT below) and lines marked "lang-allow".
# Checks:
#   1. no German word or umlaut in any tracked text file outside the allowlist
#   2. no German word in any file or directory name
#   3. lab.sh: every legacy German command and option is an alias line that calls deprecated()
#   4. the detector itself (a German sample is found, an English sample is not)
#   5. docs: no ß, no removed German command or file name, Mermaid flowcharts are TD or TB
# Marker in a file: a line containing "lang-allow" is skipped; lines between "lang-allow-begin" and
# "lang-allow-end" are skipped. Use it only for texts that are the product (output into German docs).
# Needs: python3 (standard library only). Usage: bash tests/language-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
fail=0
n=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (is '$2', want '$3')"; fail=$((fail + 1)); fi; }

OUT=$(python3 - "$R" <<'PY'
import os, re, subprocess, sys

root = sys.argv[1]

# German words that must not appear in code (lowercase; whole tokens; camelCase is split).
WORDS = set("""
aber abnahme aender aendern alle alles angelegt anlegen anpassen anwender auch aus ausgabe ausser ausnahmen
ausschluss aussen beenden beendet bei beim benoetigt benutzer benutzers bericht besitzer betriebssystem bitte
bleiben bleibt brauchen braucht damit danach danke dann darf das daten datei dateien datenbank dein deine
deinem deinen deiner dem den derselbe dieselbe diese diesem diesen dieser dieses doku duerfen durch eine einen
einer eines eingabe einmal eintraege eintragen enthaelt entfernt entscheidungen entschluesselt entsteht ergibt
erlaub ersetzen ersetzung erst erster erstell erstellt erwartungen erzeug erzeugt falsches fehlen fehler
fehlerhaft fehlt fertigen fremd fuer funde gefunden gegeben gegen geheim geheimnis geheimnisse gehoert
geloescht gemessen genau gesetzt gesperrt gestartet gibt groesse gross gueltig gueltigkeit heisst hinweis
hinzufuegen immer jede jeder jedes jetzt kann kein keine keinen keiner kennwort klartext klick knoten koennen
konfiguration kopieren kritisch laenge laeuft laufen leck leeren liegen liegt linien loesch loeschen loescht
loesung lokal lokale lokalen macht mehrmals meldet meldung meldungen menue messung messungen muessen muss
nach nachher nachweis namen neue neuer nicht nichts noch notiz notizen nur oder oeffentlich oeffentliche
oeffnet ohne ordner passen passwort pfad platte privilegiert pruef pruefen pruefung punkt punkte rechner
regeln ressourcen rueck schicken schluessel schon sich sicherheit sicherung sind soll sollen solange sonst
spalte spalten speicher sperre spitze starten startet statt stehen steht stufe traegt trocken typen ueber
unbekannt und ungueltig unter verbot verbraucher verschiebungen verschluesselt verweist verzeichnis vorhanden
vorher vorlage vorlagen waechter warnung warten weil weiter welche welle wenn werden werte wieder wiederherstellung
wird wollen wurde wurden zeigen zeigt zeile zeilen zerstoeren ziel zugang zuerst zum zur zurueck zusammen
zustand zweck zweimal vor
""".split())
UMLAUT = re.compile("[äöüÄÖÜß]")

# Allowed German text (removed from a line before it is scanned). Every entry says why.
ALLOW_TEXT = [
    # names of sections in the German docs: "section ...", "heading ...", "runbook ..." in quotes
    re.compile(r'\b(section|sections|heading|runbook)\s+"[^"]*"'),
    # files on the owner's disk and on the VM that keep their German names (existing data, see CHANGES-wave3b.md)
    re.compile(r"\.passwort\b"),
    # the drop-in was renamed to 10-k3s-safe.conf; the old name stays in the migration task that removes it
    re.compile(r"\b10-k3s-sicher\b"),
    re.compile(r"\b(?:[a-z]+/)?stufe8[bc]-block-b\.sh\b"),
    # legacy keys in lab.local.yaml that are still read
    re.compile(r"\bedge_profil(_admin)?\b"),
    # header written by older role versions, still recognised
    re.compile(r"\bStufe 8a\b"),
    # titles of the German docs site that the verify playbook checks
    re.compile(r"<title>[^<]*</title>"),
]
# Whole files that are German on purpose (text of the docs site).
ALLOW_FILES = {"zensical.toml", "scripts/public/replacements.tsv", "tests/language-tests.sh"}
# Lines of scripts/lab.sh that only map a deprecated German name to its English name.
ALIAS_LINE = re.compile(r"^\s*(--?[A-Za-z0-9-]+|[a-z0-9]+)\)\s+deprecated\s+\S+\s+\S+;")
SKIP_SUFFIX = (".png", ".svg", ".ico", ".jpg", ".gif", ".lock", ".css", ".woff", ".woff2", ".sops.yaml", ".lock.hcl", ".tfstate")


def tokens(line):
    out = []
    for tok in re.findall(r"[A-Za-zÄÖÜäöüß]+", line):
        for w in re.sub(r"([a-z])([A-Z])", r"\1 \2", tok).split():
            out.append(w.lower())
    return out


def german_in(line):
    for rx in ALLOW_TEXT:
        line = rx.sub(" ", line)
    hit = [w for w in tokens(line) if w in WORDS]
    if UMLAUT.search(line):
        hit.append("umlaut")
    return hit


def is_doc(path):
    return path.startswith("docs/") or path.endswith(".md")


def tracked(root):
    try:
        out = subprocess.check_output(["git", "-C", root, "ls-files", "-co", "--exclude-standard"], text=True,
                                      stderr=subprocess.DEVNULL)
        files = [f for f in out.split("\n") if f]
        if files:
            return files
    except Exception:
        pass
    files = []
    for dp, dn, fn in os.walk(root):
        # no git: skip VCS/cache folders and hidden tool folders (ansible/.ansible holds foreign collections); keep .github/.gitea
        dn[:] = [d for d in dn if d not in (".git", ".terraform", "__pycache__") and not (d.startswith(".") and d not in (".github", ".gitea"))]
        files += [os.path.relpath(os.path.join(dp, f), root) for f in fn]
    return files


def scan_text(text, path):
    found = []
    skipping = False
    for nr, line in enumerate(text.split("\n"), 1):
        if "lang-allow-begin" in line:
            skipping = True
            continue
        if "lang-allow-end" in line:
            skipping = False
            continue
        if skipping or "lang-allow" in line:
            continue
        if path == "scripts/lab.sh" and ALIAS_LINE.search(line):
            continue
        hit = german_in(line)
        if hit:
            found.append((path, nr, sorted(set(hit))[:4], line.strip()[:90]))
    return found


files = [f for f in tracked(root) if os.path.isfile(os.path.join(root, f))]
code_hits, name_hits, doc_hits = [], [], []
nfiles = 0
for f in files:
    if f.endswith(SKIP_SUFFIX):
        continue
    parts = re.split(r"[/._-]+", f)
    bad = [p.lower() for p in parts if p.lower() in WORDS]
    if bad and f not in ALLOW_FILES:
        name_hits.append((f, 0, bad, ""))
    if is_doc(f) or f in ALLOW_FILES:
        continue
    try:
        text = open(os.path.join(root, f), encoding="utf-8").read()
    except Exception:
        continue
    nfiles += 1
    code_hits += scan_text(text, f)

print("INFO %d code files scanned, %d words in the list" % (nfiles, len(WORDS)))


def report(name, hits):
    if not hits:
        print("OK   %s" % name)
        return
    print("FAIL %s (%d findings)" % (name, len(hits)))
    for h in hits[:25]:
        print("     %s:%s %s | %s" % (h[0], h[1], ",".join(h[2]), h[3]))


report("code: no German words or umlauts outside the allowlist", code_hits)
report("file names: no German words", name_hits)

# 3. aliases in lab.sh
labsh = open(os.path.join(root, "scripts/lab.sh"), encoding="utf-8").read()
EXPECT = {
    "abnahme": "acceptance", "geheimnisse": "secrets", "anpassen": "customize", "oeffentlich": "public",
    "waechter": "guard", "--ja": "--yes", "--zerstoeren-ok": "--destroy-ok", "--auch-image": "--include-image",
    "--neuer-age-schluessel": "--new-age-key", "--trocken": "--dry-run", "--host-keys-holen": "--fetch-host-keys",
    "--ohne-export": "--no-export", "--ersetzen": "--replace",
}
PRIVATE_ONLY = {"oeffentlich", "waechter", "--ersetzen"}  # lang-allow: these aliases exist only in the private lab.sh
for old, new in sorted(EXPECT.items()):
    if old in PRIVATE_ONLY and not re.search(r"^\s*%s\)" % re.escape(old), labsh, re.M):
        print("INFO alias %s is private-only (not in the public export): skipped" % old)
        continue
    rx = re.compile(r"^\s*%s\)\s+deprecated\s+%s\s+%s;" % (re.escape(old), re.escape(old), re.escape(new)), re.M)
    print("%s alias %s -> %s calls deprecated()" % ("OK  " if rx.search(labsh) else "FAIL", old, new))
print("%s deprecated() writes to stderr and names the removal date" % (
    "OK  " if re.search(r"deprecated\(\) \{\n  echo .*December 2026.* >&2\n\}", labsh) else "FAIL"))
others = [m.group(1) for m in re.finditer(r"^\s*(\S+)\)\s+deprecated\s", labsh, re.M) if m.group(1) not in EXPECT]
print("%s no alias besides the %d known ones (%s)" % ("OK  " if not others else "FAIL", len(EXPECT), ",".join(others)))

# 4. detector self-test
samples = [("Datei nicht gefunden", True), ("File not found", False), ("Größe prüfen", True),
           ("echo \"Primary vorher: $OLD\"", True), ("host-keys: fetch the keys", False),
           ("# section \"Namen in /etc/hosts\" of the docs", False), ("notes-demo.passwort", False)]
for s, want in samples:
    got = bool(german_in(s))
    print("%s detector: %r is %s" % ("OK  " if got == want else "FAIL", s, "German" if want else "not German"))
print("%s detector: a marked line is skipped" % ("OK  " if not scan_text("x = 'Datei'  # lang-allow: demo", "x.py") else "FAIL"))
print("%s detector: a marked block is skipped" % (
    "OK  " if not scan_text("# lang-allow-begin\nx = 'Datei'\n# lang-allow-end", "x.py") else "FAIL"))
print("%s detector: a line after the block is checked" % (
    "OK  " if scan_text("# lang-allow-begin\n# lang-allow-end\nx = 'Datei'", "x.py") else "FAIL"))

# 5. docs
OLD_NAMES = [
    "lab-geheimnisse", "lab-anpassen", "lab-oeffentlich", "lab-waechter", "scripts/oeffentlich", "oeffentlich-tests",
    "geheimnisse-erzeugen", "gitleaks-lokal", "werte-stand", "lab-backups-leeren", "policy-lab-ca-namen", "lab-ca-nur-lab-domain",
    "geheimnisse.yml", "verify-oeffentlich", "ansible/oeffentlich.yml", "ersetzungen.tsv", "denyliste.txt",
    "lab.sh abnahme", "lab.sh geheimnisse", "lab.sh anpassen", "lab.sh oeffentlich", "lab.sh waechter",
    "--zerstoeren-ok", "--auch-image", "--neuer-age-schluessel", "--host-keys-holen", "--ohne-export", "--ersetzen",
    "--trocken", "`abnahme`", "`anpassen`", "`oeffentlich`", "`waechter`", "`geheimnisse`", "`--ja`",
    "anpassen --", "abnahme --", "oeffentlich --", "waechter --", "geheimnisse --",
    "`abnahme ", "`anpassen ", "`oeffentlich ", "`waechter ", "`geheimnisse ",
]
docs = [f for f in files if is_doc(f) and not f.endswith("CHANGES-wave3b.md") and f.endswith(".md")]
ss, old_hits, mm = [], [], []
for f in docs:
    text = open(os.path.join(root, f), encoding="utf-8").read()
    if "ß" in text:
        ss.append(f)
    skipping = False
    for i, line in enumerate(text.split("\n"), 1):
        if "lang-allow-begin" in line:
            skipping = True
        if skipping:
            skipping = "lang-allow-end" not in line
            continue
        if any(o in line for o in OLD_NAMES) and not re.search(r"alias|Alias|veraltet|deprecated", line):
            old_hits.append((f, i, [o for o in OLD_NAMES if o in line][:2], line.strip()[:80]))
    for m in re.finditer(r"```mermaid\n(.*?)```", text, re.S):
        for l in m.group(1).split("\n"):
            d = re.match(r"\s*(graph|flowchart)\s+(\w+)", l)
            if d and d.group(2) not in ("TD", "TB"):
                mm.append((f, 0, [d.group(2)], l.strip()))
print("INFO %d docs scanned" % len(docs))
report("docs: no ß (de-CH)", [(f, 0, ["ß"], "") for f in ss])
report("docs: no removed German command or file name (aliases excepted)", old_hits)
report("docs: Mermaid flowcharts are TD or TB", mm)
PY
)
while IFS= read -r l; do
  case $l in
    OK*|FAIL*) n=$((n + 1)); echo "$l"; case $l in FAIL*) fail=$((fail + 1)) ;; esac ;;
    INFO*) echo "$l" ;;
    *) echo "$l" ;;
  esac
done <<< "$OUT"

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
