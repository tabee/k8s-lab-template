---
title: "ADR-0021: Notiz-Sites hinter Keycloak"
---

# ADR-0021: Notiz-Sites hinter Keycloak (oauth2-proxy statt Basic-Auth)

**Status:** angenommen

## Kontext

Die Notiz-Sites (`gitops/sites.yaml`, Chart `notes-site`) waren durch Traefik-Basic-Auth geschützt: ein Passwort
pro Site, kein Abmelden, kein gemeinsames Konto. Seit [ADR-0019](0019-keycloak-sso.md) gibt es Keycloak mit dem
Realm `lab` und der Gruppe `lab-users`. `https://notes.lab.example/` soll dahinter stehen, und das ohne
neue Liste von Sites: jede weitere Site in `sites.yaml` soll dasselbe bekommen.

## Entscheidung

1. **oauth2-proxy als Reverse-Proxy vor dem Pod `notes`**, ein kleiner Pod pro SSO-Site im Namespace der Site
   (`notes-oauth2-proxy`, Pin per Digest, Version in [Versionen](../../reference/versions.md)). Traefik leitet
   die Site an den Proxy (Port 4180); der Proxy reicht nur Anfragen mit gültiger Sitzung an `notes` weiter.
   - **Verworfen: Traefik ForwardAuth.** Mit ForwardAuth bliebe der Pod `notes` für jeden Pod im Cluster offen, der
     Traefik umgeht, und die Prüfung hinge an der Middleware-Kette (eine vergessene Middleware öffnet die Site). Beim
     Reverse-Proxy erreicht der Pod `notes` nur der Proxy (NetworkPolicy), ein Fehler in Traefik öffnet nichts.
     Der Preis: ein Pod mehr pro Site (64 MiB Limit). Die ForwardAuth-Variante bleibt möglich, sie braucht denselben
     Proxy, nur andere Argumente und eine Middleware.
2. **Ein vertraulicher Keycloak-Client `notes` für alle Sites**, im Realm als Code ([ADR-0019](0019-keycloak-sso.md)
   Punkt 3). Rücksprung-Adressen und Abmelde-Adressen erzeugt das Chart `keycloak` aus `gitops/sites.yaml`
   (Symlink `files/sites.yaml`: eine Liste), exakt und ohne Platzhalter, für alle Sites ausser `auth: basic`.
   PKCE (S256) ist Pflicht. Das Client-Geheimnis kommt als `$(env:NOTES_CLIENT_SECRET)` aus einem eigenen SOPS-Secret
   (`keycloak-notes-client`) in den Realm-Job und steht nirgends im Klartext in Git.
   - **Verworfen: ein Client pro Site.** Mehr Geheimnisse und mehr SOPS-Dateien für keinen Gewinn: alle Sites
     gehören demselben Besitzer und derselben Gruppe. Ein Client pro Site ist später möglich, ohne den Proxy zu ändern.
3. **Nur die Gruppe `lab-users`** (`--allowed-group`, Claim `groups`). Ein Konto ausserhalb der Gruppe sieht 403.
   Die Sitzung erneuert der Proxy alle 4 Minuten gegen Keycloak: wer aus der Gruppe fällt oder gesperrt wird,
   verliert den Zugang dort, nicht erst nach 10 Stunden.
4. **Abmelden beendet die Keycloak-Sitzung.** `/oauth2/sign_out` löscht das Cookie und ruft im Hintergrund das
   Abmelden bei Keycloak mit `id_token_hint` auf (`--backend-logout-url`). Ohne das bliebe man bei Keycloak angemeldet,
   und der nächste Besuch loggte sofort wieder ein. Die Abnahme prüft genau das.
5. **Sitzung im Cookie, kein Zustand.** Kein Redis, kein Volume. Der Proxy braucht darum weder Backup noch
   Wiederherstellung.
6. **Zwei Wege zu Keycloak.** Der Browser geht zu `https://sso.<domain>` (öffentlich, Traefik, nur `/realms/lab/`
   und `/resources/`). Der Proxy tauscht den Code und holt die Schlüssel über `http://keycloak.keycloak.svc:8080`
   (`--skip-oidc-discovery`, damit er beim Start nicht auf Keycloak wartet und das Zertifikat der Lab-CA nicht
   kennen muss).
7. **Netz.** Der Proxy hat nur DNS, den Pod `notes` (8080) und Keycloak (8080) als Ziel, kein `ipBlock`, kein Internet,
   keinen API-Server-Zugriff. Der Pod `notes` nimmt nur noch den Proxy an. Keycloak bekommt `keycloak-allow-notes-proxy`.
   Die Egress-Abnahme (`verify-egress.yml`) prüft die Richtlinie und sondiert vom Proxy-Pod aus.
8. **Geheimnisse aus `lab.sh init`.** Das Client-Geheimnis (`keycloak-notes-client-secret`) und der Cookie-Schlüssel je
   Site (`notes-<site>-cookie`, 32 Zeichen) kommen über die bestehende Geheimnis-Liste. Das Secret `notes-oidc`
   pro Site legt Ansible an (die Namespaces der Notiz-Sites gehören Ansible, wie `notes-repo`); Argo CD hat dort
   keine Secrets.
9. **`auth: basic` je Site als Notausgang.** `auth` in `sites.yaml` (Vorgabe `sso`) schaltet pro Site zurück auf die
   alte Basic-Auth, ohne Proxy und ohne Keycloak-Eintrag. Bei `sso` gibt es keine Basic-Auth mehr (keine zwei Wege
   in die Site). Ansible entfernt das alte Secret `notes-auth` einer SSO-Site.

## Folgen

- **Reihenfolge beim Einführen.** Erst `lab.sh init` (neue Dateien), dann die neue SOPS-Datei einchecken und **vor
  oder mit** dem Chart pushen (sonst bricht `secrets-keycloak`), dann `lab.sh sync-host` (legt `notes-oidc` an).
  Zwischen Push und `sync-host` wartet der Proxy-Pod auf das Secret: die Site ist in dieser Zeit nicht erreichbar.
  Nicht während `rebuild --restore`; den Weg beschreibt [Notiz-Sites](../../how-to/notes-sites.md#umstellung-der-bestehenden-site-notes).
- **Lebenslauf.** `rebuild`, `rebuild --restore`, `purge`, `up`: der Proxy entsteht aus Git (Argo CD) und Ansible
  (Secret) neu und braucht keine Sicherung. Das Client-Geheimnis liegt in SOPS (Git) und wird beim Wiederaufbau mit
  dem Realm neu angewendet; der Cookie-Schlüssel liegt in `~/.config/k8s-lab/`. Verliert man die Datei, erzeugt
  `lab.sh init` einen neuen, und alle Sitzungen enden (einmal neu anmelden). Backup-Alarme sind nicht betroffen
  (kein Zustand); die Datenbank von Keycloak sichert wie bisher `keycloak-db`.
- **Ausfall von Keycloak** sperrt die Notiz-Sites (bestehende Sitzungen laufen bis zur nächsten Erneuerung weiter,
  danach nicht). Notausgang: `auth: basic` und `lab.sh sync-host`.
- **Speicher.** 24 MiB Request, 64 MiB Limit pro SSO-Site ([Memory-Budget](../../reference/memory-budget.md)).
- **Echte Client-IP.** Der Proxy läuft ohne `--reverse-proxy` und sieht darum nicht die Adresse des Browsers;
  die Weiterleitungsadresse ist fest eingetragen, nicht aus Kopfzeilen abgeleitet.
- **Nicht in der Probe getestet** (nur im echten Lab prüfbar): Durchsetzung der NetworkPolicies durch k3s,
  Traefik-Grenzen für Kopfzeilen und Cookies, Argo-Sync.

## Siehe auch

- [Notiz-Sites](../../how-to/notes-sites.md), [Keycloak im Lab](../../how-to/keycloak.md)
- [ADR-0019](0019-keycloak-sso.md), [ADR-0004](0004-sops-age-ksops.md)
