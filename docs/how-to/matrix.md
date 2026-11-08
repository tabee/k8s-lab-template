---
title: Matrix im Lab
---

# Matrix im Lab (Synapse und Element Web)

**Ziel:** ein familieninterner Matrix-Dienst neben Gitea. Synapse spricht nur mit Clients im Lab, Element Web ist der
Web-Client. Ein Neuaufbau (`lab.sh rebuild`) zieht den Dienst frisch hoch, legt den Admin an und sichert Datenbank
und Dateien. Ein bestehender Server (mit `server_name`, Schlüssel, Konten, Räumen und Medien) kommt über den
[Matrix-Import](matrix-import.md) hinein; ohne ihn bleibt es bei der frischen Instanz.

Warum Föderation aus ist, warum `server_name` eine eigene Quelle hat und warum der Signaturschlüssel von aussen
kommen darf: [ADR-0016](../concepts/decisions/0016-matrix-federation-off.md).

## Adressen

| Was | Wert | Quelle |
|---|---|---|
| Client-API, Medien | `https://matrix.<domain>/` | `domain` in `lab.yaml`; das Zertifikat heisst `matrix.<domain>` |
| Web-Client | `https://element.<domain>/` | dasselbe, Name `element.<domain>` |
| `server_name` (Identität) | Standard ein Name unter der Lab-Domain | **nur** `matrix_server_name` in `lab.yaml` |

Die öffentlichen Namen folgen der Domain, weil die Lab-CA nur Namen unter dieser Domain signiert
([ADR-0007](../concepts/decisions/0007-lab-ca-name-constraints.md)). `server_name` folgt einer Domain-Änderung
**nicht**: `lab.sh customize` schreibt ihn nach dem Ersetzen der Domain wieder auf den Wert aus `lab.yaml`
(`serverName` in `gitops/charts/matrix/values.yaml`, die einzige Kopie). Sonst stünde er nirgends fest.

Das Benutzerverzeichnis durchsucht alle Konten (`user_directory.search_all_users: true`, wie auf dem alten Server): bei
wenigen Familienkonten findet man jeden auch ohne gemeinsamen Raum. Element Web startet dunkel (`default_theme: dark`),
mit der Landesvorwahl `CH` und ohne Anmeldung per E-Mail oder Telefonnummer (`disable_3pid_login`). Alles andere aus der
Konfiguration des alten Servers (Anruf-Dienst, URL-Vorschau, Rate Limits) gehört nicht ins Lab.

## Föderation ist aus

!!! warning "Keine Föderation, nicht verhandelbar"
    Synapse hat nur den Client-Listener auf Port 8008. `federation_domain_whitelist` ist `[]` (nicht weggelassen).
    `/.well-known/matrix/server` wird nicht ausgeliefert. URL-Vorschau ist aus, es gibt keinen Identity-Server und
    keine Key-Server. Die NetworkPolicy des Namespace `matrix` lässt für Synapse und Element nur DNS und den eigenen
    Namespace zu. Postgres und K8up dürfen API und S3, der Pooler nur die API. Ein Weg ins Internet fehlt.

Die Abnahme (Phase 18, `verify-matrix.yml`) beweist das von aussen: die Client-Versionen antworten, die
Föderations-Version antwortet 404 mit `M_UNRECOGNIZED`, `/.well-known/matrix/server` ist 404, eine Registrierung
wird abgewiesen.

`federation_ip_range_blacklist` in der Synapse-Konfiguration sperrt zusätzlich jedes Ziel. Das ist eine Einstellung
von Synapse, keine NetworkPolicy. Die Policy bleibt die Grenze.

## Admin und Konten

Die Registrierung ist aus (`enable_registration: false`). Gäste sind aus. Nur der Admin legt Konten an (Admin-API
von Synapse).

Bei jedem Start legt der Einstieg des Pods den Admin an, wenn er fehlt, und lässt ein bestehendes Konto in Ruhe
(das Passwort wird nicht zurückgesetzt). Die Zugangsdaten kommen aus dem Secret `matrix-admin`, das gemeinsame
Geheimnis der Registrierung aus `matrix-registration`. Dateien auf dem Steuerrechner (Modus 0600, Werte nie im Log):

| Datei | Geheimnis |
|---|---|
| `~/.config/k8s-lab/matrix-k3s-lab-admin.user` | Benutzername, Vorgabe `lab-admin` |
| `~/.config/k8s-lab/matrix-k3s-lab-admin.pw` | Passwort |
| `~/.config/k8s-lab/matrix-k3s-lab-registration.secret` | gemeinsames Geheimnis, nur für das Anlegen |
| `~/.config/k8s-lab/matrix-k3s-lab-db.pw` | Datenbank-Benutzer `matrix` |
| `~/.config/k8s-lab/matrix-k3s-lab-signing.key` | optional, siehe unten |

`lab.sh init` legt die fehlenden Dateien an und verschlüsselt sie nach `secrets/matrix/`. Ein zweiter Lauf meldet
`SKIP`. Die Karte: [Geheimnis-Karte](../reference/secrets-map.md).

Anmeldung im Browser: `https://element.<domain>/`, Benutzer aus der Admin-Datei, Homeserver ist der `server_name`.
Die Abnahme meldet sich im Pod an und druckt nur `login ok`.

## Signaturschlüssel

Der Schlüssel darf von aussen kommen: eine Zeile in `matrix-k3s-lab-signing.key`, dann `lab.sh init`. Fehlt die
Datei, verschlüsselt `init` ein leeres Secret. Der erste Start erzeugt den Schlüssel auf dem Volume
(`/data/signing.key`) und K8up sichert ihn mit dem Medien-Store.

!!! warning "Neuaufbau wirft einen nur auf dem Volume liegenden Schlüssel weg"
    `lab.sh rebuild` ist ein sauberer Start ([ADR-0009](../concepts/decisions/0009-rebuild-is-clean-start.md)): die
    Platte der VM ist neu, der Postgres-Bucket wird geleert, der K8up-Bucket bleibt. Ein frischer Synapse mit leerem
    Secret erzeugt einen **neuen** Schlüssel. Der alte Schlüssel im K8up-Archiv gehört zur gelöschten Datenbank.
    Wer die Identität behalten will, legt den Schlüssel vor dem Start in die Datei (und damit ins SOPS-Secret) oder
    stellt das Volume aus K8up wieder her. Weicht der mitgelieferte Schlüssel von dem auf dem Volume ab, bleibt der
    Pod stehen und druckt keinen Schlüssel.

Macaroon- und Form-Geheimnis liegen ebenfalls nur auf dem Volume (`/data/macaroon.secret`, `/data/form.secret`),
nie im Git. K8up sichert sie mit.

## Datenbank, Dateien, Sicherung

| Was | Wie | Wohin |
|---|---|---|
| Datenbank `matrix-db` | CloudNativePG, zwei Instanzen, Barman, sofortiges erstes Backup | Präfix `matrix` im CNPG-Bucket |
| Medien, Signaturschlüssel, Macaroon, Form | K8up, PVC `matrix-data` (5 GiB) | eigenes restic-Repository, Präfix `matrix` im K8up-Bucket |
| Verbindung zur Datenbank | PgBouncer im Session-Modus (`matrix-db-pooler-rw`) | nur im Namespace |

Gleiches S3-Geheimnis und gleiches restic-Passwort wie Gitea, aber **nicht** dasselbe restic-Repository. Ein
Transaction-Pooler bricht Synapse; darum Session-Modus. Die Zeitpläne stehen in den Manifesten und liegen nach
denen von Gitea, damit nicht beide zugleich auf rustfs schreiben. Der K8up-Zeitplan läuft nicht sofort: die Abnahme
legt das erste erfolgreiche Datei-Backup selbst an und **behält** das Objekt `verify-<Lauf>`, damit der Restore-Test
ein frisches K8up-Backup sieht. Ältere `verify-*` löscht der nächste Lauf.

## Abnahme

`bash scripts/lab.sh acceptance` führt Matrix als letzte Phase aus (`verify-matrix.yml`), nach den Alarmen. Sie
prüft den Stand im Git, die beiden Applications, die Föderation von aussen, die Anmeldung des Admins, ein fertiges
CNPG-Backup, das Wiederherstellen einer Markierung aus K8up in den Wegwerf-Namespace `matrix-verify` und die
Egress-Proben. Der Namespace `matrix-verify` wird danach gelöscht. Das Backup-Objekt bleibt.

## Restore-Test

`bash scripts/lab.sh restore-drill` spielt nach dem Gitea-Lauf Matrix in den Wegwerf-Namespace `matrix-drill`.
Ablauf, Zeiten und die Zeile `RESTORE-DRILL RESULT`: [Restore-Test](restore-drill.md). Scheitert der Gitea-Lauf,
startet der Matrix-Lauf nicht.

!!! warning "Der Test schreibt zwei Markierungen auf das laufende Volume"
    Vor dem frischen Backup legt er `/data/drill-marker` und `/data/media_store/drill-marker` an (nur die Lauf-Kennung).
    Die Dateien bleiben im nächsten Backup. Er druckt weder Passwort noch Schlüssel, nur ob Hash und Markierung
    stimmen und ob die Anmeldung gelingt.

## Ressourcen

Der Namespace erzwingt PSA `restricted`. Synapse läuft als Benutzer 991 (die Vorgabe des Images, ohne `gosu`),
Element als 101. Jeder Container hat Request und Limit; die `LimitRange` `lab-memory` ist dieselbe wie bei whoami.
Die Summe der Limits liegt mit Matrix über dem Speicher der VM ([Issue 9](https://github.com/tabee/k8s-lab-template/issues/9)). `memory_budget_enforce` bleibt `false`:
`OVERBUDGET` warnt, `NOLIMIT`, `BADLIMIT` und Speicherdruck bleiben rot. Details:
[Memory-Budget](../reference/memory-budget.md).

## Zweiter Lauf

Ein zweites `lab.sh up` ändert nichts: Ansible meldet `changed=0`, die Applications `matrix` und `secrets-matrix`
bleiben `Synced` und `Healthy`. `lab.sh init` und `lab.sh customize` melden `SKIP`, solange die Werte gleich sind.

## Siehe auch

[ADR-0016](../concepts/decisions/0016-matrix-federation-off.md), [Geheimnis-Karte](../reference/secrets-map.md),
[Abnahme](acceptance.md), [Restore-Test](restore-drill.md), [Alarm](alerts.md)
