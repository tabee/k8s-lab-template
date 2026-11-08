---
title: "ADR-0013: Backup-Replikat mit rsync und rrsync"
---

# ADR-0013: Backup-Replikat mit rsync und rrsync

**Status:** angenommen

## Kontext

Das Primärziel (rustfs) liegt auf demselben Datenträger wie die VM-Platte ([ADR-0008](0008-backup-outside-vm.md)).
[Issue 3](https://github.com/tabee/k8s-lab-template/issues/3) verlangt eine Kopie auf einem zweiten Rechner im Heimnetz (Ubuntu 24.04, nur
SSH, keine Admin-Rechte im Betrieb). Der Cluster schreibt weiter an **ein** Ziel.

## Entscheidung

Das Replikat ist ein **Verzeichnis**, gefüllt per **rsync über SSH** mit einem eigenen Schlüssel, der in
`authorized_keys` mit `restrict`, `from=` und einem erzwungenen Befehl `rrsync -no-del <Verzeichnis>` steht. Timer
auf dem Steuerrechner (alle 15 Minuten Spiegel, täglich Prüfsummen), ein Stempel auf dem Replikat
für die Frische.

Verworfen:

- **S3 zu S3 (zweites rustfs, `mc mirror`, rclone):** braucht auf dem Replikat einen laufenden Dienst, Zugangsdaten und
  einen zweiten S3-Zugriff, dazu ein Werkzeug, das dieses Repo nicht kennt. Mehr Fläche für weniger Gewinn.
- **restic auf das Replikat:** die Daten im Bucket sind schon ein restic-Repository (K8up) und Barman-Dateien; ein
  zweites Backup-Produkt über dem ersten verdoppelt Schlüssel und Fehlerbilder. Ein Restore bräuchte restic **und**
  dann erst rustfs.
- **SSH mit Shell und Skripten auf dem Replikat:** verlangt Vertrauen in die Skripte dort. `rrsync` erlaubt dem
  Schlüssel nur rsync, nur in ein Verzeichnis, mit `-no-del` nur Hinzufügen.

Das Verzeichnis ist das **Datenverzeichnis von rustfs**. Ein Restore ist: Verzeichnis zurückholen, rustfs darauf
starten ([Backup-Replikat](../../how-to/backup-replica.md)).

## Folgen

- Das RPO ist das Spiegel-Intervall (15 Minuten) plus Ausschalten des Replikat-Rechners. Frische wird gemessen und
  alarmiert.
- Mit `-no-del` wächst das Replikat; es schützt vor einem Erpresser-Programm auf dem Steuerrechner nur gegen das Löschen,
  nicht gegen das Überschreiben. Die Vertrauensgrenze steht als Warnung in der Anleitung.
- Ob rustfs die gespiegelten Metadaten (`.rustfs.sys`: Benutzer, Richtlinien) zuverlässig wieder ausliefert, ist nur
  live prüfbar. Bis dahin ist das Replikat **eine Kopie der Dateien**, kein bewiesenes Ziel.
- Der persönliche Schlüssel wird einmal benutzt (Installation); der Spiegel nur den eigenen.

## Siehe auch

[Backup-Replikat](../../how-to/backup-replica.md), [Backup ausserhalb der VM](0008-backup-outside-vm.md)
