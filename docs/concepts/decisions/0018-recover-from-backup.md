---
title: "ADR-0018: Wiederherstellung nur zur Laufzeit"
---

# ADR-0018: Wiederherstellung nur zur Laufzeit

**Status:** angenommen

## Kontext

CNPG liest `bootstrap` nur beim Anlegen des Clusters. Ein volles Archiv unter dem `serverName` aus Git verweigert das Plugin (`Expected empty archive`). Die Notfall-Commits vom 2026-11-01 haben `bootstrap.recovery` und die Schreib-Namen `*-r3` in den damaligen drei `cluster.yaml` festgehalten. Ein frisches `up`, eine fremde Installation und die öffentliche Kopie suchen dann ein Archiv, das es bei ihnen nicht gibt. `rebuild` leert denselben Bucket, und die Manifeste wollten trotzdem daraus lesen.

Den neuen `serverName` zu committen verschiebt das Problem nur. Der nächste Lauf müsste wieder committen, und Git wäre nie wieder eine frische Installation.

## Entscheidung

Die Cluster in Git bleiben auf `bootstrap.initdb` mit dem ursprünglichen `serverName` (`pg-lab`, `gitea-db`, `matrix-db` und seit [ADR-0019](0019-keycloak-sso.md) `keycloak-db`; die Liste steht in `scripts/lab-restore-render.py`).

`bash scripts/lab.sh rebuild --restore` ist der Wiederherstellungs-Weg. Er leert rustfs nicht, ändert kein Git und pusht nicht. Er fragt doppelt (das Wort `restore`, dann der VM-Name). `--yes` überspringt das nicht. `--no-export` gilt nicht.

`scripts/lab-restore-render.py` liest die Initdb-Manifeste und die Archiv-Ordner auf der Platte. Quelle ist die höchste Generation, deren neuestes abgeschlossenes Basis-Backup ein `end_wal` hat und deren Segment unter `wals/` liegt. Eine höhere Generation ohne dieses Segment fällt weg. Der nächste Name muss leer sein; ist er belegt, bricht der Lauf ab und nennt das Präfix. Die Recovery-Spec landet nur im Cluster, in einem Verzeichnis ausserhalb des Repos.

Läuft die VM noch, nimmt `rebuild --restore` vor dem Abbau für jeden der vier Cluster (auch `keycloak-db`) ein neues CNPG-Basis-Backup und für Gitea und Matrix je ein neues K8up-Backup (Keycloak hat kein Volume) und wartet, bis sie fertig sind. Die Altersgrenze dafür ist `backup_max_age_h` in `lab_values`; sie zeigt auf `restore_drill_max_age_h` (eine Zahl). Fehlt ein Cluster oder ein Schedule, oder schlägt ein Backup fehl, bleibt die VM stehen. Einen Schalter, der das überspringt, gibt es nicht. Ist die VM schon aus, kann dieses Backup nicht mehr laufen. Der Abbau stützt sich dann auf das Archiv auf der Platte und prüft das Alter nicht, damit ein Desaster-Restore eines älteren Archivs möglich bleibt.

Damit Argo CD die Cluster nicht aus Git mit `initdb` anlegt, solange der Bucket voll ist, setzt `argocd.yml` für diesen Lauf `resource.exclusions` auf `postgresql.cnpg.io/Cluster`. Nach dem Apply entfernt `ansible/restore-clusters.yml` den Ausschluss. Die Applications `db-lab`, `gitea` und `matrix` tragen `ignoreDifferences` für `bootstrap`, `externalClusters` und den Schreib-`serverName`, plus `RespectIgnoreDifferences=true`. Ein frisches `up` legt die Cluster aus Git an, weil noch kein lebendes Objekt da ist. Ein wiederhergestellter Cluster bleibt beim Recovery-Spec. Git bleibt `initdb`.

Die Dateien von Gitea und Matrix kommen aus dem neuesten K8up-Snapshot, dessen `spec.paths` dieses PVC enthält (`/data/<claim>`). Die Restore-Spec setzt `spec.snapshot` auf die volle `spec.id` und `spec.paths` auf genau diesen Pfad. Fehlt so ein Snapshot, bricht der Lauf mit `take a K8up backup first` ab und nimmt nicht das neueste Snapshot des ganzen Repos. Danach prüft ein Pod das PVC: bei Gitea ist `git/gitea-repositories` nicht leer, bei Matrix hat `/data/signing.key` Inhalt. Erst dann geht der Sync wieder an (`ansible/recover-files.yml`). `restore-drill` bleibt der Wegwerf-Beweis.

**Nachtrag nach dem ersten echten Lauf (2026-11-02/03).** Zwei Wettläufe haben den Lauf gestoppt. Erstens ist die CRD `Established`, bevor der Webhook von CNPG antwortet. `restore-clusters.yml` wartet deshalb vor dem Apply auf das Deployment des Operators (`Available`) und auf einen bereiten Endpunkt des Service `cnpg-webhook-service` (EndpointSlice). Das Apply wiederholt sich nur bei Webhook-Fehlern. Zweitens heilt die App `root` (App of Apps mit `selfHeal`) die angehaltenen Kinder `gitea` und `matrix` zurück. `recover-files.yml --tags pause` hält darum zuerst `root` an, `--tags resume` setzt `root` als Letztes wieder in den Sollzustand (`argocd_root_automated`, die einzige Definition, auch für den Bootstrap). Läuft die Pause schief, bleibt `root` nicht still aus: Die Rescue-Meldung und die Warnung von `lab.sh` nennen den Befehl `recover-files.yml --tags resume`. Der Wartungsmarker für den Alarm steht in [Alarm](../../how-to/alerts.md#wartungsmarker).

**Nachtrag: Plugin und erstes Backup.** Vor dem Apply wartet `restore-clusters.yml` auch auf das barman-cloud-Plugin (Deployment `Available`, Service `barman-cloud` mit bereitem Endpunkt), weil der Operator es für die Recovery sofort anspricht. Nach dem Restore fehlen im neuen k3s alle `Backup`-Objekte. Damit Alarm und `wal_ready` nicht bis zum nächsten Zeitplan `no completed backup` melden, nimmt `rebuild --restore` als letzte Phase je Datenbank ein CNPG-Backup und je Volume ein K8up-Backup (`--prefix post-restore`). Ein Fehler dort bricht den fertigen Restore nicht ab, er wird als Warnung mit dem Befehl zum Wiederholen gemeldet.

`rebuild` ohne `--restore` leert den Postgres-Bucket weiter. `up` bricht bei altem WAL weiter ab.

**Nachtrag nach dem zweiten Lauf (2026-11-03).** Der Lauf kam bis «Restore Gitea and Matrix files» und blieb beim Löschen des Datei-PVC in `Terminating` hängen. Die Pause hatte das Deployment auf 0 gesetzt, als es noch nicht existierte (`not found` galt als in Ordnung). Der laufende erste Sync von `gitea` legte es danach an, und sein Pod hängte das leere PVC ein (`pvc-protection`). Die Pause bleibt früh (vor dem Warten auf Argo CD), weil nur so kein Pod auf dem leeren Volume anläuft, und sie darf den ersten Sync nicht überspringen: Das ObjectStore der Datenbank liegt in den Manifesten der App, ohne ihn würde das «Databases healthy» nie grün. Sie ist darum deterministisch: Auto-Sync aus, laufenden Sync abwarten, einmal von Hand synchronisieren, falls noch keiner gelungen ist, Deployment auf 0, warten bis kein Pod das PVC einhängt. Der Restore prüft das nochmals (Pause-Guard, Deployment auf 0, Pod beim Namen nennen, `Terminating`-PVC abwarten) und löscht erst dann. Die Warnung von `lab.sh` nennt je nach Stand den genauen Befehl.

**Nachtrag nach dem dritten Lauf (2026-11-03).** Der Lauf brach bei «Apply CNPG recovery specs» ab: Das Plugin-Deployment wartete 12 Minuten auf zwei TLS-Secrets, die cert-manager erst spät ausstellte. Das Warten auf das Deployment allein war falsch gestuft. `restore-clusters.yml` wartet jetzt in einer Kette (cert-manager, Zertifikate, Secrets, Deployment) mit **einem** Budget, `restore_plugin_timeout_min` in `group_vars/all/restore.yml`, und greift höchstens je einmal ein (Sync von `cnpg` anstossen, wenn er `Failed` ist; den Plugin-Pod löschen). `argocd.yml` bleibt unverändert: Dort zu warten machte cert-manager nicht schneller, und die Kette startet ohnehin gleich danach. Dazu kommt ein Wächter: Nach einem Abbruch läuft eine VM mit womöglich leeren Volumes, und ein weiterer `rebuild --restore` hätte davon «frische Backups» genommen, die K8up als neueste Snapshots des Tages aufbewahrt. Darum schreibt `lab.sh` vor dem Abbau eine Markierung (`restore_state_file`), die erst der Schritt `verify` löscht, und prüft eine laufende VM vor dem Backup (Markierung, Cluster, Auto-Sync, Datei-Volumes). `LAB_RESTORE_START_OVER=1` beginnt bewusst neu, ohne Backup der kaputten VM. Beim Restore werden Snapshots ohne Dateien übersprungen. Das Risiko des nächtlichen K8up-Zeitplans bleibt, solange eine halb gebaute VM über 20:30 UTC läuft; es steht in [Neuaufbau](../../how-to/rebuild.md#restore-halb).

## Folgen

- Git beschreibt wieder eine frische Installation. Eine fremde `up` mit leerem Bucket macht `initdb`.
- Der lebende `serverName` nach einem `--restore` steht nicht in Git. Die Applications ignorieren genau diese Felder. Ein Wechsel von Image, Instanzen oder Speicher bleibt sichtbar.
- `bootstrap` ist nach dem Anlegen unveränderlich. Ignorieren heisst auch: eine spätere Änderung von Datenbank oder Owner in Git heilt einen laufenden Cluster nicht. Dafür braucht es einen neuen Cluster.
- Solange eine VM noch mit dem Recovery-Stand aus den Notfall-Commits läuft, kann der erste Sync nach diesem Commit `OutOfSync` zeigen. Der Webhook von CNPG weist ein Umschreiben von `bootstrap` zurück. Der nächste Sync, der `RespectIgnoreDifferences` schon kennt, lässt den lebenden Stand stehen. Daten, die nur in der VM lagen, sind damit nicht gesichert. Der Stand der Buckets bleibt.
- Die ersten echten Läufe von `rebuild --restore` blieben beim Webhook-Wettlauf (2026-11-02) und beim Datei-PVC (2026-11-03) stehen; die Korrekturen stehen oben. Ob der Weg selbständig durchläuft, verfolgt [Issue 4](https://github.com/tabee/k8s-lab-template/issues/4).
- Eine laufende VM, die nach einem Abbruch halb gebaut aussieht, wird weder gesichert noch abgerissen, bevor jemand entscheidet (Wächter, Markierung). Das kostet im Fehlerfall einen zusätzlichen Befehl und schützt das letzte gute Backup.
- Ein laufendes Lab wird nicht abgerissen, solange das frische Backup fehlt oder fehlschlägt. `down` und `export` legen kein Backup an; ihnen reicht die WAL-Prüfung, und ein Cluster ohne abgeschlossenes Backup ist auch dort ein Abbruch.

## Siehe auch

[Neuaufbau](../../how-to/rebuild.md), [Datenbank wiederherstellen](../../how-to/restore-database.md), [ADR-0009](0009-rebuild-is-clean-start.md), [ADR-0014](0014-restore-drill-throwaway-namespace.md), [ADR-0017](0017-wal-before-vm-stop.md)
