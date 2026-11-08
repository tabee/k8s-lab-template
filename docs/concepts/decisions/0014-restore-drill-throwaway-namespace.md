---
title: "ADR-0014: Restore-Test im Wegwerf-Namespace"
---

# ADR-0014: Restore-Test im Wegwerf-Namespace

**Status:** angenommen

## Kontext

[Issue 4](https://github.com/tabee/k8s-lab-template/issues/4) beschrieb den Beweis so: PVC und CNPG-Cluster **in den echten Namen** löschen,
mit einem neuen `serverName` nur für diesen Lauf wiederherstellen, danach in den Zustand aus Git zurück. Dabei widerspricht
sich der Plan an einer Stelle: Der Barman-Cloud-Plugin verweigert ein **nicht leeres** Archiv (`Expected empty archive`,
siehe [Datenbank wiederherstellen](../../how-to/restore-database.md)). Ein Cluster, der nach dem Test wieder mit dem **alten**
`serverName` aus Git läuft, bräuchte ein leeres Archiv unter diesem Namen, also ein geleertes Backup. Bliebe der neue
`serverName` im Cluster, hätte Git ihn dauerhaft zu tragen. Ausserdem löscht der Ablauf die einzige Kopie der Live-Daten,
bevor der Beweis erbracht ist.

## Entscheidung

Der Test läuft in einem **Wegwerf-Namespace** `<gitea>-drill` mit neuen Volumes. Der Wegwerf-Cluster startet per
`bootstrap.recovery` aus dem echten Archiv (nur lesend, ohne eigenen WAL-Archivierer), die Dateien kommen per
K8up-Restore in ein leeres PVC. Verglichen wird mit dem Fingerabdruck der laufenden Datenbank. Das echte Gitea, sein
PVC und das echte Archiv werden nicht angefasst; ein Argo-Sync-Stopp ist unnötig.

Der Befehl heisst `lab.sh restore-drill` (englisch, kein deutscher Alias), fragt doppelt wie `purge` und verlangt den
frischen Export.

## Folgen

- Bewiesen ist der Weg aus dem **Objektspeicher**, nicht der Ausfall der VM-Platte selbst. Der echte Ausfall ist
  `rebuild --restore` ([ADR-0018](0018-recover-from-backup.md)). Git bleibt dabei auf `initdb`.
- Es gibt keinen Zustand, den Git nach dem Test zurückholen müsste; ein «schmutziger Baum» kann nicht entstehen.
- Der Lauf braucht Platz und Speicher für einen zweiten Postgres in der VM ([Speicherbudget](../../reference/memory-budget.md)).
- Der Test mit dem Replikat ist ein manueller Durchlauf ([Restore-Test](../../how-to/restore-drill.md#replikat)).

## Siehe auch

[Restore-Test](../../how-to/restore-drill.md), [Backup und Restore](../backup-and-restore.md), [ADR-0018](0018-recover-from-backup.md) (echter Ausfall, `rebuild --restore`)
