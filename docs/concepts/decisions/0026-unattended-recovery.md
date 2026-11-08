# ADR 0026: Kernbetrieb von optionalen Sites trennen

## Entscheidung

Die festen Sites `docs` und `notes-*` sind keine Voraussetzung für den Kernbetrieb.
Ein privates Notiz-Repo darf unerreichbar sein, ohne Restore und Trust-Freigabe zu
verhindern. Die CLI meldet diese Zustände sichtbar als Warnung bzw. nicht durchgeführte
Prüfung. Alle übrigen Anwendungen und die Datenbanken bleiben zwingend.

Datei-Restore, Resume und Trust-Freigabe bleiben eine geordnete Erfolgskette. Ein
fehlgeschlagener Datei-Restore löst niemals automatisch Resume aus.

Der Graph-Build verwendet eine lizenzierte, commit-gepinnte Kopie im Repo mit
Prüfsummen statt eines zusätzlichen privaten Git-Servers. Der Renderer darf weiterhin
öffentliche, gepinnte Build-Abhängigkeiten benötigen.

Import-Abnahmebelege werden auf dem jeweiligen gesicherten `/data`-Volume abgelegt.
Nach einem Restore werden daraus nur dauerhafte ConfigMap-Felder rekonstruiert;
Pause-/Scale-Zustand wird nicht übernommen. Alte Backups ohne Beleg bleiben explizit
ohne historische Import-Abnahme. Sie werden nicht mit einer frisch erfundenen
Vergleichsbasis als erfolgreich ausgegeben.

## Folgen

Eine grüne Kern-Abnahme bestätigt nicht die optionalen Sites. Diese lassen sich mit
ihren eigenen Prüf-Playbooks abnehmen. Frische Sicherungen übernehmen bestehende
Import-Belege, bevor sie Volumes sichern; vor einem Neuaufbau genügt deshalb der
normale Backup-Weg. Ein Beleg enthält private Metadaten, aber keine Secrets, und
bleibt auf dem privaten Volume bzw. in dessen geschützter Sicherung.

Details: [Neuaufbau](../../how-to/rebuild.md),
[CLI](../../reference/lab-sh.md).
