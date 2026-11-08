---
title: "ADR-0015: Gitea-Import per gitea dump"
---

# ADR-0015: Gitea-Import per `gitea dump`

**Status:** angenommen

## Kontext

Die Produktions-Forge läuft als Gitea auf einem VPS (Docker Swarm, Postgres). Das Lab-Gitea soll ihren Inhalt aufnehmen,
zuerst als Probelauf für den späteren Umzug der Produktion, später auch als Weg «Dump in das Cluster-Gitea einspielen»
nach einem Neuaufbau. Der VPS ist nur über das VPN erreichbar und wird dabei **nur lesend** benutzt. Der Dump enthält
Geheimnisse (`app.ini`, Passwort-Hashes, Tokens) und darf nie unverschlüsselt auf einer Platte liegen.

Zur Wahl standen: Repo für Repo per API und Git (verliert Benutzer und Passwort-Hashes), ein Datenbank-Dump von Hand
(an die Gitea-Version gebunden, keine Dateien) oder `gitea dump` (Datenbank, Repos, Daten in einem Archiv).

## Entscheidung

1. **Methode `gitea dump`.** Das kleine Skript `scripts/gitea-import-vps-dump.sh` läuft auf dem VPS, schreibt den Dump in
   ein Temp-Verzeichnis **im Container** (danach gelöscht) und streamt ihn **verschlüsselt** nach aussen (age, die
   Empfänger aus `.sops.yaml`; alternativ sops-Binärformat für kleine Forges). `gitea dump --database postgres` liefert
   die SQL-Datei immer in Postgres-Syntax, auch bei SQLite oder MySQL als Quelle.
2. **Importiert wird nur, was Repos und Zugriff braucht:** Benutzer, Organisationen, Teams, Repos (mit Wiki, LFS,
   Anhängen, Avataren) samt Issues, Pull Requests und Releases. **Nicht importiert:** Webhooks, Vorlagen-Repos
   (`is_template`), Spiegel, Tokens, Sitzungen, 2FA, SSH-/GPG-/Deploy-Schlüssel, Secrets, OAuth2, Actions, Pakete.
   Das filtert `scripts/gitea-import/filter.sql` in einem Staging-Schema, bevor etwas Echtes angefasst wird.
3. **Passwort-Hashes bleiben**, wenn der Algorithmus bekannt ist (argon2, bcrypt, pbkdf2, scrypt): das gleiche
   Gitea-Format gilt auf beiden Seiten, das alte Passwort funktioniert weiter. Sonst warnt der Import.
4. **Datenbank per Schema-Tausch:** Der Dump wird in das Schema `gi_stage` der laufenden CNPG-Datenbank geladen und
   gefiltert; erst nach dem Herunterskalieren von Gitea tauscht **eine Transaktion** `public` gegen `gi_stage`. Ein
   Fehler vorher ändert nichts Echtes (Gitea wird wieder hochgefahren, Argo CD zurückgestellt). Danach läuft
   `gitea migrate` (Dump älter als Lab ist erlaubt, **neuer nicht**: die Version des Labs muss grösser oder gleich sein).
5. **Idempotent über die Prüfsumme der verschlüsselten Datei:** gleicher Dump = `SKIP` (nur Abnahme); leeres Lab oder
   Ergebnis eines früheren Imports = Import; **fremder Inhalt = `ABORT`**, ausser mit `--replace` (zerstörerisch, die
   einzige Rückfrage `[y/N]`, vorher K8up- und CNPG-Sicherung). Der Zustand steht im ConfigMap `gitea-import-state`.
6. **Argo CD wird für die Dauer angehalten** (Auto-Sync von `root` und `gitea` aus, danach wie vorher), sonst skaliert
   der Selbstheilungs-Sync Gitea mitten im Import hoch.
7. **Hilfs-Pods** im Namespace `gitea` tragen das Label `app.kubernetes.io/name: gitea-import`; die bestehenden Policies
   (`allow-egress-dns`, `allow-egress-same-namespace`, `allow-same-namespace`) decken sie ab. **Keine neue
   NetworkPolicy**, keine Öffnung nach aussen: der Dump kommt per `kubectl exec` und Pipe vom Steuerrechner.
8. **LFS wird im Lab eingeschaltet** (`LFS_START_SERVER: true` in `values-gitea.yaml`), weil sonst importierte
   LFS-Objekte nicht ausgeliefert werden.

## Folgen

- Der Import ist wiederholbar und dient als Probe für den Umzug auf einen neuen Server: gleicher Ablauf, anderes Ziel.
- Der Klartext liegt nur in einem tmpfs-Verzeichnis (mktemp), das beim Beenden überschrieben und gelöscht wird (Trap).
- Während des Imports ist Gitea für einige Minuten nicht erreichbar.
- Nach einem Bruch **nach** dem Tausch bleibt Gitea absichtlich aus; erneuter Aufruf setzt fort, `recover` fährt
  zurückgestellte Dinge wieder hoch.
- Benutzer mit externer Anmeldung (OAuth/LDAP) werden lokale Benutzer ohne Passwort: Passwort-Reset nötig.
- Später am Lab vorgenommene Änderungen machen den Inhalt für den nächsten Import «fremd» (Fingerabdruck stimmt nicht
  mehr), dann braucht es `--replace`.
- Nicht prüfbar ohne den echten VPS: die Version und der Zustand des Produktions-Dumps. Dafür gibt es `--dry-run`.

## Siehe auch

[Gitea-Import](../../how-to/gitea-import.md), [Gitea wiederherstellen](../../how-to/restore-gitea.md),
[ADR-0014](0014-restore-drill-throwaway-namespace.md)
