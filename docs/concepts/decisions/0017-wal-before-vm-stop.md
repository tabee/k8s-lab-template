---
title: "ADR-0017: VM erst stoppen, wenn das End-WAL im Archiv liegt"
---

# ADR-0017: VM erst stoppen, wenn das End-WAL im Archiv liegt

**Status:** angenommen

## Kontext

Am 2026-11-01 meldete das CNPG-Backup von `matrix-db` die Phase `completed`. Im Bucket lag das WAL nur bis zum Segment vor dem konsistenten Punkt. `pg-lab` und `gitea-db` liessen sich abspielen, `matrix-db` nicht (`WAL ends before consistent recovery point`). `export` fährt die VM herunter. Das offene WAL-Segment ist dann noch nicht hochgeladen, und ein Backup-Objekt `completed` beweist das Gegenteil nicht.

## Entscheidung

`lab.sh down`, `lab.sh export` und `lab.sh rebuild --restore` rufen `scripts/lab-wal-ready.py` auf, solange die VM läuft. Das Skript schreibt zuerst einen winzigen WAL-Eintrag (`pg_logical_emit_message`: keine Tabelle, keine Daten, damit auch ein ruhender Cluster ein nicht leeres Segment hat), schaltet das WAL um und wartet, bis `pg_stat_archiver.last_archived_wal` mindestens das `endWal` des letzten abgeschlossenen Backups jedes Clusters erreicht. Schlägt das fehl, bleibt die VM laufen. Einen Schalter, der diese Prüfung überspringt, gibt es nicht. `purge` löscht die Buckets absichtlich und wartet nicht.

## Folgen

Ein Desaster-Abbau behält ein abspielbares Archiv, sofern vorher ein abgeschlossenes Basis-Backup existiert. Ohne abgeschlossenes Basis-Backup bricht das Skript ab und stoppt die VM nicht. Eine leere Cluster-Liste (noch kein CNPG) bleibt in Ordnung. Alter und K8up-Snapshots prüft dieser Weg nicht; das macht `rebuild --restore`, solange die VM noch läuft. Die Wiederherstellung ist `rebuild --restore` ([ADR-0018](0018-recover-from-backup.md)), nicht ein Commit in den Cluster-Manifesten.

## Siehe auch

[Backup und Restore](../backup-and-restore.md), [ADR-0018](0018-recover-from-backup.md) (`rebuild --restore`, Git bleibt `initdb`)
