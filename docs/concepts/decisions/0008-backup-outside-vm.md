---
title: "ADR-0008: Backup ausserhalb der VM, ein Primärziel"
---

# ADR-0008: Backup ausserhalb der VM, ein Primärziel

**Status:** angenommen

## Kontext

Ein Backup, das mit der VM verschwindet, ist keines.

## Entscheidung

rustfs (S3) läuft rootless auf dem Steuerrechner, die VM erreicht es über das virtuelle Netz. CNPG (Barman-Cloud-Plugin) und K8up (restic) schreiben an genau **ein** Ziel mit je einem eigenen Bucket-Benutzer mit Policy nur für den eigenen Bucket.

## Folgen

Standardmässig teilen sich VM-Platte und rustfs denselben Datenträger ([Issue 3](https://github.com/tabee/k8s-lab-template/issues/3)). Transport per HTTP. Mehrere gleichzeitige Ziele sind bewusst ausgeschlossen: Zwei parallele WAL-Ströme erzeugen halbe Sicherungen.

## Siehe auch

[Backup und Restore](../backup-and-restore.md)
