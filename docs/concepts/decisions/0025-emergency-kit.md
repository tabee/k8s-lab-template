---
title: "ADR-0025: Notfall-Kit auf einem USB-Stick"
---

# ADR-0025: Notfall-Kit auf einem USB-Stick

**Status:** angenommen (Wunsch des Betreibers: mit **einem** Befehl alle Schlüssel auf einen Stick kopieren und den
Neuaufbau aus GitHub durchspielen können)

## Kontext

Das Repo auf GitHub enthält den Code und die **verschlüsselten** Secrets (`*.sops.yaml`). Alles, was zum Entschlüsseln
und Wiederherstellen nötig ist, liegt nur auf dem Steuerrechner: der age-Schlüssel, die Passwörter der Datenbanken
und Sicherungen, die Lab-CA, der Signaturschlüssel für Commits, die Deploy-Keys, der Vertrauensanker
([Geheimnis-Karte](../../reference/secrets-map.md)). Fällt der Rechner aus, sind GitHub und die Sicherungen zwar da,
aber unlesbar. Der Passwortmanager deckt die wichtigsten Stücke ab, aber nur, wenn jemand daran gedacht hat und nichts
von Hand abgetippt werden muss: es sind rund zwei Dutzend Dateien.

Zusätzlich fehlte eine Anleitung, die den Fall «nur noch Rechner, GitHub und Stick» von Anfang bis Ende beschreibt,
und die Vorabprüfung kannte den Fall nicht, dass `origin` im frischen Klon selbst der GitHub-Spiegel ist.

## Entscheidung

1. **Ein Befehl, ein Archiv:** `lab.sh kit export DIR` kopiert alle Dateien der Tabelle in `scripts/emergency-kit.sh`
   (`kit_table`) in **ein** Archiv `k8s-lab-kit.tar.age`. Die Pfade bleiben erhalten, damit `import` jede Datei an den
   ursprünglichen Ort zurücklegt. Die Tabelle ist die **eine Stelle**; ein Test vergleicht sie mit `secrets.yml`.
2. **Verschlüsselung mit `age -p` (Passphrase):** der Stick braucht keinen Schlüssel, der selbst verloren gehen könnte.
   Die Passphrase wird nie gespeichert und nie gedruckt; sie gehört in den Passwortmanager. `age -p` liest sie nur vom
   Terminal, darum verweigert `export` ohne Terminal. Das ist Absicht: kein Weg, die Passphrase in eine Variable oder
   eine Datei zu legen.
3. **Manifest im Klartext daneben:** Pfade, Rechte, Grössen und die SHA-256 der Klartextdateien, dazu der
   Vertrauensanker, die GitHub-Adresse und die SHA-256 des Archivs. **Nie Inhalt.** Die SHA-256 verraten nichts über
   die Dateien, weil alles im Kit entweder zufällig erzeugt wurde (Passwörter, Schlüssel) oder keine Rolle spielt;
   ein Angreifer mit dem Stick kann damit keinen Wert raten. Dasselbe Manifest liegt **im** Archiv. `verify` und
   `import` brechen ab, wenn beide abweichen: ein vertauschtes Manifest bleibt nicht unbemerkt.
4. **`README-NOTFALL.txt` daneben:** eine kurze Anleitung auf Deutsch, die auch ohne Repo lesbar ist.
5. **Pflicht und bequem:** *Pflicht* ist, was sich nicht neu erzeugen lässt (age-Schlüssel, Passwörter, Lab-CA,
   Signaturschlüssel, Matrix-Signaturschlüssel, Anker). *Bequem* ist, was `init` oder ein Playbook neu erzeugen
   könnte, dessen Verlust aber manuelle Arbeit bei GitHub, Gitea oder dem Replikat kostet (Deploy-Keys, VM-Schlüssel,
   Alarm- und Replikat-Konfiguration). Eine fehlende Pflichtdatei bricht `export` ab und nennt alle fehlenden;
   `--allow-missing` ist der ausdrückliche Ausweg. Die Kubeconfig und das Argo-CD-Admin-Passwort sind abgeleitet und
   nicht im Kit.
6. **Eigene Zusätze:** `~/.config/k8s-lab/kit-extra.list` nimmt weitere Pfade auf (zum Beispiel den Schlüssel zum alten
   Server), die dieses Repo nicht kennen kann. Sie zählen zu den bequemen Dateien und stehen im selben Manifest.
7. **Kein Klartext auf der Platte:** `verify` und `import` entschlüsseln in ein 0700-tmpfs (`XDG_RUNTIME_DIR`,
   `/dev/shm` oder `/run/user/UID`), prüfen dort und überschreiben (`shred`) und entfernen die Dateien beim Beenden,
   auch bei einem Fehler. Gibt es kein tmpfs, bricht der Befehl ab.
8. **`export` verweigert Ziele im Repo** und in jedem Git-Arbeitsbaum (ein Kit gehört nie in Git) sowie nicht
   schreibbare Ziele. Auf demselben Datenträger wie `$HOME` warnt er.
9. **`import` überschreibt nie still:** zuerst ein Plan (`SAME`, `NEW`, `DIFFERS`). Bei einer abweichenden Datei bricht
   er ab und ändert **nichts**; mit `--force` bleibt die alte Datei als `*.before-kit-ZEIT` (0600). Schlüsseldateien
   bekommen 0600, neue Verzeichnisse 0700.
10. **Vorabprüfung im Klon aus GitHub:** ist `origin` selbst der GitHub-Spiegel, gibt es keinen zweiten, unabhängigen
    Zeugen mehr. Der Preflight sagt das mit einer Warnung und prüft **nur** den Anker und die Signaturen. Scheitert
    der Abruf (keine Anmeldung, kein Netz), vergleicht er mit dem zuletzt geholten Stand, statt «Git-Server nicht
    erreichbar» zu melden, und fragt nie nach einem Passwort (`GIT_TERMINAL_PROMPT=0`). Steht `source` dabei auf
    `gitea`, ist das ein Fehler mit dem Hinweis auf `kit import`. Das Verhalten für normale Klone bleibt gleich.

## Verworfene Alternativen

| Option | Warum nicht |
|---|---|
| Alles im Passwortmanager | über zwanzig Dateien von Hand, Fehler beim Abtippen, keine Rechte, keine Prüfung |
| Archiv mit einem **age-Schlüssel** statt Passphrase | der Schlüssel müsste selbst irgendwo liegen und wäre dort der schwächste Punkt |
| Passphrase aus einer Variablen oder Datei (für Skripte) | age kennt das nicht; ein Umweg über `expect` oder eine Datei würde sie sichtbar machen |
| Das Kit mit SOPS verschlüsseln | SOPS braucht den age-Schlüssel, der im Kit selbst liegt |
| Das Kit mit im Repo (verschlüsselt) | ein einmal gepushtes Kit lässt sich nie zurückholen, und ein Fehler beim Verschlüsseln wäre öffentlich |
| Klartext-Kopie auf dem Stick, Stick im Tresor | ein verlorener Stick wäre ein verlorenes Lab |
| Nur Pflichtdateien | der Verlust der Deploy-Keys und der Konfiguration des Replikats kostet Zeit; sie sind klein und gehören dazu (`--must-only` bleibt möglich) |
| Mit `gh` oder `git` Dateien einsammeln | die Dateien liegen ausserhalb des Repos |

## Folgen

- Die Passphrase ist die einzige Hürde: wer sie und den Stick hat, hat alle Geheimnisse des Labs. Das entspricht dem
  Schutz des Passwortmanagers; der Stick liegt nicht beim Rechner, die Passphrase nicht auf dem Stick.
- Nach jeder Rotation von Geheimnissen ist das Kit zu erneuern ([Anleitung](../../how-to/notfall-neuaufbau.md#vorbereiten)).
  `verify` zeigt, ob der Stand stimmt, aber nicht, ob er aktuell ist.
- Die Sicherungen (Daten) gehören **nicht** ins Kit. Sie liegen in rustfs auf dem Steuerrechner und als Kopie auf dem
  Replikat-Rechner ([Backup-Replikat](../../how-to/backup-replica.md)).
- Im Klon aus GitHub schützen nur Anker und Signaturen. Der Anker kommt aus dem Kit (verschlüsselt) und steht
  zusätzlich im Klartext-Manifest als Gedächtnisstütze.
- Der Weg ist in einem Testlauf durchzuspielen ([Notfall-Neuaufbau](../../how-to/notfall-neuaufbau.md)): erst wenn
  Wegstellen, Neuaufbau, Import der Daten, Sicherung, Abriss und `rebuild --restore` einmal gelaufen sind, gilt er als
  bewiesen.

## Siehe auch

- [Referenz Notfall-Kit](../../reference/emergency-kit.md)
- [Notfall-Neuaufbau](../../how-to/notfall-neuaufbau.md)
- [ADR-0023: Signierte Commits und Quellvertrauen](0023-signed-main-and-source-trust.md)
- [ADR-0024: GitHub als schaltbare Quelle](0024-github-as-switchable-source.md)
