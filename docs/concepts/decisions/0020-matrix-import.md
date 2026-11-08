---
title: "ADR-0020: Matrix-Import per Datenbank-Dump und Schema-Tausch"
---

# ADR-0020: Matrix-Import per Datenbank-Dump und Schema-Tausch

**Status:** angenommen

*Nummern: 0019 ist Keycloak ([ADR-0019](0019-keycloak-sso.md)), 0021 sind die Notiz-Sites hinter Keycloak. Diese
Nummer 0020 blieb frei und bleibt, damit nichts umnummeriert werden muss.*

## Kontext

Die Produktions-Matrix läuft als Synapse auf dem alten VPS (Docker Swarm, Postgres). Das Lab-Matrix soll sie aufnehmen,
zuerst als Probelauf für den Umzug, später auch als Weg «Dump einspielen» nach einem Neuaufbau. Bestehende Clients
müssen danach weiterlaufen: gleicher `server_name`, gleicher Signaturschlüssel, gleiche Konten mit Passwort, gleiche
Räume und Medien, und die Geräte- und Schlüsseldaten der Ende-zu-Ende-Verschlüsselung (sonst können Geräte alte
Nachrichten nicht mehr lesen). Der VPS wird **nur lesend** benutzt, der Dump enthält Geheimnisse und liegt nie
unverschlüsselt auf einer Platte. Die Föderation bleibt aus ([ADR-0016](0016-matrix-federation-off.md)). Die
Produktion läuft später auf einem Rechner mit nur 8 GB RAM.

Zur Wahl standen: Konten und Räume über die Admin-Schnittstelle neu anlegen (verliert Verlauf und Schlüsseldaten, und
die Schnittstelle müsste offen sein), ein Dump der Tabellen von Hand (an das Schema gebunden) oder der ganze
`pg_dump` samt Medienspeicher.

## Entscheidung

1. **Methode: ganzer `pg_dump` plus `tar` von Medienspeicher und Signaturschlüssel.** `scripts/matrix-import-vps-dump.sh`
   läuft auf dem VPS, führt nur `docker ps`, `docker inspect` und `docker exec` aus (`pg_dump`, `tar`), schreibt **keine
   Datei** und streamt **verschlüsselt** nach aussen (age, die Empfänger aus `.sops.yaml`; auf dem VPS gibt es `age`,
   aber weder `sops` noch einen privaten Schlüssel). Der Stand der Datenbank kommt zuerst, die Medien danach. Zu Beginn
   steht eine kleine Meta-Datei: Quell-Host, Erstellzeit, Versionen, `server_name`, öffentlicher Schlüssel.
2. **Zuerst die Identität, dann der Inhalt.** `matrix-import prepare DUMP` braucht kein Cluster und schreibt
   `server_name` (`matrix_server_name` in `lab.yaml`, die eine Stelle, dazu dieselbe Zeile in `lab.local.yaml`) und den Signaturschlüssel (die Datei, die
   `init` nach SOPS verschlüsselt). Danach `init`, `customize`, Commit, Push: **Argo CD baut Matrix mit der Identität des
   Dumps.** Der Import selbst verlangt, dass ConfigMap und SOPS-Secret zum Dump passen, sonst `ABORT`. Das ist **ein**
   Weg für beide Fälle (Lab von Anfang an mit dem Server, oder Import in ein laufendes Lab); der Schlüssel liegt nie im
   Klartext in Git, und ein `rebuild --restore` behält die Identität, weil der Einstiegspunkt der Chart anhält, wenn
   Volume und Secret sich unterscheiden.
3. **Datenbank per Schema-Tausch in einer Transaktion.** Synapse wird auf 0 skaliert, dann benennt eine Transaktion
   `public` in `mxi_old` um, legt ein neues `public` an, lädt den Dump, prüft (Zahlen, Fremdschlüssel, Konto des
   Lab-Admins) und löscht erst dann `mxi_old` mit `COMMIT`. Der Trockenlauf macht dasselbe und `ROLLBACK`. Ein Fehler
   davor ändert nichts Echtes. Der Dump gilt nur, wenn er vollständig ist (die ganze Strecke wird einmal gelesen, das
   `tar` braucht seinen Abschluss).
4. **Nie Klartext auf der Platte.** Der Dump wird mehrfach direkt in Pipes entschlüsselt (Meta, Prüfung, SQL, Medien,
   Geheimnisse). Das kostet CPU, aber keinen Speicher und keine Datei. Auch Geheimnisse (`signing.key`, `macaroon.secret`,
   `form.secret`) gehen nur durch Pipes und werden nie ausgegeben.
5. **Idempotent über die SHA-256 der Datei und einen Fingerabdruck des Inhalts:** gleicher Dump = `SKIP` (nur Abnahme);
   leeres Lab oder unverändertes Ergebnis eines früheren Imports = Import; **fremder Inhalt = `ABORT`**, ausser mit
   `--replace` (zerstörerisch, einzige Rückfrage `[y/N]`, vorher K8up- und CNPG-Sicherung). Zustand: ConfigMap
   `matrix-import-state`.
6. **Version:** das Lab muss **gleich oder neuer** sein als die Quelle (Synapse migriert nur vorwärts). Das Alter des
   Dumps wird angezeigt (Quell-Host, Erstellzeit); älter als `--max-age` (24 Stunden) warnt.
7. **Die Konfiguration der Quelle wird nicht übernommen.** Das Chart des Labs bleibt die eine Stelle der Konfiguration;
   der Import vergleicht und zeigt Unterschiede als `INFO` (Föderation und Registrierung bleiben aus).
8. **Die Admin-Schnittstelle bleibt gesperrt:** `/_synapse/admin` wird im Ingress (Traefik-Route mit Vorrang
   und Middleware `deny-admin-api`) abgewiesen. Die Middleware erlaubt nur `192.0.2.1/32` (TEST-NET-1, wird nie
   geroutet), also nie eine echte Quelle. **`127.0.0.1/32` wäre falsch**: ein `kubectl port-forward` in den
   Traefik-Pod kommt von Loopback und käme durch. Der Import braucht die Schnittstelle nicht: er arbeitet mit SQL und
   Dateien.
9. **Sicherung danach.** Nach dem Import folgen ein K8up-Backup der Dateien und ein CNPG-Base-Backup samt
   WAL-Prüfung (`matrix-import backup` auch einzeln), damit `rebuild --restore` den importierten Stand
   zurückbringt. `rebuild --restore` erzwingt zusätzlich selbst eine frische Sicherung und fragt weiter doppelt.
10. **Schlank für 8 GB:** nur zwei kurzlebige Hilfs-Pods (psql 64 MiB angefordert, 512 MiB Limit; Dateien 128/768 MiB),
    `restricted`, ohne Service-Account-Token, am Ende gelöscht. Keine neue NetworkPolicy, kein residenter Dienst. Während
    des Imports ist Synapse aus.
11. **Aufräumen nach Abbruch gehört zum Werkzeug.** Ein beendeter `kubectl exec` stoppt das `psql` im Hilfs-Pod nicht:
    eine offene Transaktion und ihre Sperren bleiben, und Synapse hängt danach beim Start in der Migration. Darum
    schliesst `recover` die Sitzungen über den CNPG-Primary (nur solange Synapse aus ist), ein echter Import schliesst
    verwaiste Sitzungen vor dem Laden, setzt vor dem Löschen von `mxi_old` ein `lock_timeout` und das Hilfs-Pod hält
    TCP-Keepalives.

## Folgen

- Der Import ist wiederholbar und dient als Probe für den Umzug: gleicher Ablauf, anderes Ziel.
- Synapse ist während des Imports einige Minuten nicht erreichbar.
- Wer auf einem laufenden Lab erst später die Identität wechselt, sieht Synapse im `CrashLoopBackOff`, bis der Import
  Schlüssel, Datenbank und Medien ersetzt hat. Die Dokumentation sagt das.
- Das Konto des Lab-Admins (`ensure-admin`) wird beim Start angelegt, wenn es fehlt. Heisst ein Konto im Dump gleich,
  bricht der Import ab (die Chart würde `M_USER_IN_USE` als Erfolg werten und ein fremdes Konto zum Admin machen).
- Später am Lab vorgenommene Änderungen machen den Inhalt für den nächsten Import «fremd» (Fingerabdruck), dann braucht
  es `--replace`.
- Standardgrenzen für Anmeldungen (`rc_login`) gelten im Lab statt der gelockerten Werte der Quelle: Familienmitglieder
  hinter einer Adresse können beim gleichzeitigen Neuanmelden auf `429` stossen.
- Mit der Keycloak-Reihe muss `allow_existing_users: true` im `oidc_providers`-Eintrag stehen, sonst würde ein
  Keycloak-Login ein Konto verweigern, das schon importiert ist (oder ein neues anlegen). Der Import warnt. Der
  Schalter `oidcAllowExistingUsers` ist Teil der Reihe, Standard `false`, und wird erst nach dem Import eingeschaltet.
  Dann darf es in Keycloak nie einen Benutzer `lab-admin` geben (siehe [Matrix-Import](../../how-to/matrix-import.md)).
- Nicht prüfbar ohne den echten VPS: Version und Zustand des Produktions-Dumps. Dafür gibt es den Befehl `--check` auf
  dem VPS und `--dry-run` im Lab.

## Siehe auch

[Matrix-Import](../../how-to/matrix-import.md), [Matrix im Lab](../../how-to/matrix.md),
[ADR-0015](0015-gitea-import-dump.md), [ADR-0016](0016-matrix-federation-off.md),
[ADR-0018](0018-recover-from-backup.md)
