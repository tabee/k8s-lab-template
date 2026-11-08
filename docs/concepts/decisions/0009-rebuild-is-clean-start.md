---
title: "ADR-0009: Neuaufbau ist ein sauberer Start, kein Restore"
---

# ADR-0009: Neuaufbau ist ein sauberer Start, kein Restore

**Status:** angenommen

## Kontext

Ein Neuaufbau soll reproduzierbar sein (gemessen: 23 min 36 s am 2026-10-30). Ein Restore ist ein anderes, selteneres Verfahren mit anderen Risiken.

## Entscheidung

`lab.sh rebuild` leert den Postgres-Bucket (`BUCKET_MODUS=leeren`), weil CNPG nie in ein Archiv mit Dateien schreibt. Restore bleibt eine bewusste, getrennte Anleitung. Vor jedem `down` gibt es einen Export der VM (Fallschirm), der höchstens 24 Stunden alt sein darf.

## Folgen

Nach einem `rebuild` sind die Daten des Labs weg. Wer sie braucht, folgt der Restore-Anleitung ([Issue 4](https://github.com/tabee/k8s-lab-template/issues/4): Beweis aus dem Backup ohne alte Platte).

## Siehe auch

[Neuaufbau](../../how-to/rebuild.md), [ADR-0018](0018-recover-from-backup.md) (`rebuild --restore`, ohne den Bucket zu leeren, Git bleibt `initdb`)
