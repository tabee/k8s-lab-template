---
title: "ADR-0012: Öffentliche Kopie per Export mit Wächter"
---

# ADR-0012: Öffentliche Kopie per Export mit Wächter

**Status:** angenommen

## Kontext

Das Repo enthält persönliche Werte (Namen, Adressen, Schlüssel-Fingerprints, Domains). Eine öffentliche Fassung soll entstehen, ohne dass jemand sie von Hand bereinigt.

## Entscheidung

In der privaten Fassung erzeugt `lab.sh public` die Kopie aus `git archive HEAD`: Ausschlussliste, Overlays, feste Textersetzungen, Entfernen markierter Blöcke, Ersetzungsliste, Link-Prüfung. Der **Wächter** liest das Ergebnis mit einer Denyliste und einer Entropieprüfung und bricht ab, wenn etwas übrig ist. Der Export schreibt nie in das private Repo.

## Folgen

Das Verfahren ist so gut wie seine Listen. Die Ersetzungen sind pfadgebunden; neue Seiten brauchen oft Einträge in `allowed.txt` oder `replacements.tsv`.

## Siehe auch

[Öffentliche Kopie](../../how-to/public-release.md)
