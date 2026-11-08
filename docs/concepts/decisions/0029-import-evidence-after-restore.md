# ADR-0029: Import-Belege ausserhalb des Clusters

- Status: Angenommen
- Datum: 2026-11-08

## Kontext

Die ConfigMaps der Import-Abnahme können beim Neuaufbau verschwinden. Das bedeutet
nicht, dass die importierten Daten fehlen. Ein Lieferschein muss unabhängig vom
Cluster erhalten bleiben. Die bisherigen Hooks-/Doctor-Prüfungen von
`recover-files.yml --tags verify` liefern keine Vorher-Zählwerte.

## Entscheidung

Der gefilterte Import-Beleg bleibt auf dem gesicherten Daten-Volume und zusätzlich
atomar auf dem Steuer-PC unter `~/k8s-lab-data/import-state/` erhalten. Lokale Dateien
haben `0600`, die Belegverzeichnisse `0700`; der Bereich ist an Kontext, Namespace
und Deployment gebunden. Geheimnisse und temporärer Pause-/Scale-Zustand sind
keine Bestandteile des Belegs.

Vor frischen Sicherungen eines laufenden `rebuild --restore` werden aktuelle
Datenbank-Zählwerte in denselben Beleg aufgenommen. `accept` stellt eine fehlende
ConfigMap zuerst vom Volume, ersatzweise vom Steuer-PC wieder her. Es vergleicht
die Vorher-Zählwerte als Untergrenzen und führt weiterhin die ursprünglichen
Manifest-, Datei- und HTTP-Prüfungen durch. Ein neuer Import entfernt alte
Restore-Zählwerte.

Beide Abnahmen laufen nach dem Restore automatisch. Ein Fehler ist eine explizite
Warnung, kein Abbruch des wieder laufenden Dienstes. Der manuelle `accept`-Aufruf
bleibt bei Fehlern rot. Ein fehlender Beleg ist `SKIP`, niemals ein erfundener Erfolg.

## Folgen

- Ein alter Backup-Stand ohne Beleg wird durch diese Änderung nicht nachträglich beweisbar.
- Neue Objekte nach dem Resume dürfen Zählwerte erhöhen; Zählwerte alleine beweisen
  keine vollständige Wiederherstellung einzelner Objekte oder Mediendateien.
- Der Restore-Exitcode ist kein Abnahmebeweis. Ergebnisse stehen im Log und müssen
  bei Warnungen mit beiden manuellen Abnahmen nachgeprüft werden.
- Ein umbenannter Kontext oder neuer Steuer-PC übernimmt keinen lokalen Beleg eines
  anderen Bereichs. Der Volume-Beleg bleibt dann die primäre Rückfallquelle.

Ablauf und Grenzen: [Neuaufbau, Import-Abnahme](../../how-to/rebuild.md#optionale-sites-und-import-abnahme).
