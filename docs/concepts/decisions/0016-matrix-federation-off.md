---
title: "ADR-0016: Matrix ohne Föderation"
---

# ADR-0016: Matrix ohne Föderation, eine Quelle für `server_name`

**Status:** angenommen

## Kontext

Das Lab bekommt einen Matrix-Dienst (Synapse und Element Web) nach dem Muster von Gitea: Argo-CD-Application,
CloudNativePG, K8up, NetworkPolicy, Zertifikat der Lab-CA, Admin aus einem Secret. Der Dienst ist familienintern.
Föderation mit anderen Servern ist ausgeschlossen. Ein späterer Import soll den `server_name` des bisherigen
Servers übernehmen; dieser Eintrag legt den Dienst nur frisch an.

Zur Wahl standen ein fertiges Helm-Chart von upstream (zieht einen eigenen Betrieb und oft Föderation mit) und
Manifeste im Muster von Gitea. Das Image von Synapse startet als root und wechselt per `gosu` auf Benutzer 991,
sobald es root ist oder die Variable `UID` gesetzt ist. Pod Security `restricted` verbietet beides.

## Entscheidung

1. **Föderation ist aus, an mehreren Stellen zugleich.** Nur der Client-Listener (Port 8008).
   `federation_domain_whitelist: []` steht in der Konfiguration, es wird nicht weggelassen.
   `serve_server_wellknown: false`, keine Key-Server, URL-Vorschau aus, `federation_ip_range_blacklist` sperrt
   jedes Ziel. Die NetworkPolicy lässt für Synapse und Element keinen Weg ins Internet (nur DNS und der eigene
   Namespace). Die Abnahme prüft von aussen, dass die Föderations-Version 404 mit `M_UNRECOGNIZED` antwortet und
   `/.well-known/matrix/server` 404 ist.
2. **Eine Quelle für `server_name`.** Der Schlüssel `matrix_server_name` in `lab.yaml` (Standard ein Name unter der
   Lab-Domain). `lab.sh customize` schreibt ihn nach dem Ersetzen der Domain nach `serverName` in
   `gitops/charts/matrix/values.yaml`. Öffentliche Namen (`matrix.<domain>`, `element.<domain>`) folgen der Domain,
   weil die Lab-CA nur solche Namen signiert. Der `server_name` folgt ihr nicht.
3. **Eigenes Chart nur für die Konfiguration**, Images und die übrigen Objekte als Manifeste wie bei Gitea
   (Digest in den Deployments, damit der Pin-Check sie sieht). Kein weiteres Chart-Repository.
4. **Signaturschlüssel von aussen oder beim ersten Start.** Das SOPS-Secret ist optional und leer erlaubt. Ist es
   gesetzt und das Volume leer, wird der Schlüssel installiert. Ist das Volume schon belegt und der mitgelieferte
   Schlüssel anders, bleibt der Pod stehen, ohne Material zu drucken. Fehlt beides, erzeugt der erste Start den
   Schlüssel auf dem Volume. K8up sichert Volume samt Schlüssel. Macaroon- und Form-Geheimnis entstehen ebenso
   nur auf dem Volume, nie im ConfigMap.
5. **Admin bei jedem Start, Registrierung aus.** Das gemeinsame Geheimnis liegt im Secret, nicht in der
   Konfiguration. Fehlt der Admin, wird er angelegt. Existiert er, bleibt das Passwort. Die Abnahme meldet sich
   an und druckt nur `login ok`.
6. **Datenbank im Session-Pooler.** Ein Transaction-Pooler bricht die vorbereiteten Statements von Synapse.
   Zwei Instanzen, Barman, Präfix `matrix`. K8up nutzt dasselbe restic-Passwort wie Gitea und ein **eigenes**
   Repository (Präfix `matrix`).
7. **Pod Security `restricted`.** Synapse läuft direkt als 991, ohne `gosu` und ohne die Variable `UID`. Element
   läuft als 101, das Root-Dateisystem ist nur lesbar, `ALL` ist gedroppt. Die `LimitRange` ist die der anderen
   Arbeits-Namespaces.
8. **Abnahme und Restore-Test.** Phase 18 prüft Föderation, Admin, CNPG-Backup und ein K8up-Restore einer
   Markierung. Das erfolgreiche Objekt `verify-<Lauf>` bleibt liegen, damit der Restore-Test ein frisches
   K8up-Backup sieht (Gitea löscht seines). Der Restore-Test läuft danach in `matrix-drill`, vergleicht die
   Benutzerzahl, den Schlüssel (nur Gleichheit) und eine Anmeldung. Er schreibt vorher zwei Markierungen auf das
   **laufende** Volume. Scheitert Gitea, startet Matrix nicht.
9. **Die Matrix-Senke der Alarme bleibt aus.** Synapse steht, die Registrierung ist zu, ein Bot-Token wird nicht
   angelegt. `backup_alert_matrix_enabled` bleibt `false`. Der Cluster `matrix-db` und der Namespace `matrix`
   stehen in den Backup-Prüfungen.

## Folgen

- Ein Neuaufbau erzeugt einen neuen Signaturschlüssel, wenn das Secret leer ist. Der Schlüssel aus einem früheren
  K8up-Backup gehört zur gelöschten Datenbank. Identität über einen Neuaufbau hinweg braucht den Schlüssel im
  Secret oder ein Restore des Volumes.
- Solange der Standard-`server_name` gleich `matrix.<domain>` ist, sieht ein naiver Textvergleich beide nicht
  auseinander. Die Prüfung verlangt deshalb `.Values.serverName` in den Vorlagen und verbietet den festen Namen
  dort.
- Das Speicherbudget ist schon ohne Matrix über der VM (`memory_budget_enforce: false`). Matrix vergrössert die
  Summe. Ein `OVERBUDGET` warnt. Fehlt ein Limit oder hat der Knoten Speicherdruck, ist die Abnahme rot.
- Phase 2 (Import) setzt nur `matrix_server_name` und bringt Daten mit. Sie ist nicht Teil dieses Entscheids, sondern
  steht in [ADR-0020](0020-matrix-import.md).
- Der erste Start von Element kann an einem weiteren beschreibbaren Verzeichnis scheitern. Dann wird das leere
  Verzeichnis ergänzt, die Policy bleibt `restricted`.

## Siehe auch

[Matrix im Lab](../../how-to/matrix.md), [ADR-0007](0007-lab-ca-name-constraints.md),
[ADR-0009](0009-rebuild-is-clean-start.md), [ADR-0014](0014-restore-drill-throwaway-namespace.md),
[ADR-0015](0015-gitea-import-dump.md)
