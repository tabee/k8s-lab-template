---
title: Anleitungen
---

# Anleitungen

Anleitungen lösen eine konkrete Aufgabe. Sie setzen voraus, dass das Lab läuft
und du den Zusammenhang kennst oder in den [Erklärungen](../concepts/index.md)
nachlesen kannst.

## Betrieb

<div class="grid cards" markdown>

-   :material-restart: **[Neuaufbau](rebuild.md)**

    ---

    `up`, `rebuild`, `down`, `purge`: was bleibt, was geht, wie lange es dauert.

-   :material-check-decagram-outline: **[Abnahme](acceptance.md)**

    ---

    Messen und beweisen, dass das Lab so läuft wie beschrieben.

-   :material-package-down: **[VM exportieren und zurückholen](export-and-restore-vm.md)**

    ---

    Abbild der VM vor `down`, Rückweg nach einem Fehler.

-   :material-bug-outline: **[Fehlersuche](troubleshooting.md)**

    ---

    Symptome, Ursachen und die Lehren aus dem Neuaufbau-Drill.

</div>

## Netz, Zertifikate und Zugang

<div class="grid cards" markdown>

-   :material-shield-lock-outline: **[Netz-Kante und Profil `edge`](edge-profile.md)**

    ---

    Wer erreicht SSH, API, Admin-Oberfläche und Apps; Profil ausprobieren.

-   :material-certificate-outline: **[Lab-CA vertrauen](trust-lab-ca.md)**

    ---

    Die öffentliche CA-Datei auf Browsern und Geräten einrichten.

-   :material-autorenew: **[CA-Rotation](ca-rotation.md)**

    ---

    Die Lab-CA tauschen, mit Gegenprobe.

-   :material-earth: **[Öffentliches Zertifikat](public-certificate.md)**

    ---

    Optionaler ACME-Aussteller `lab-acme` per DNS-01.

-   :material-view-dashboard-outline: **[Argo CD bedienen](argocd-access.md)**

    ---

    Oberfläche, CLI, Initial-Passwort und Notausgang.

</div>

## Geheimnisse

<div class="grid cards" markdown>

-   :material-key-outline: **[Geheimnisse anlegen und rotieren](secrets.md)**

    ---

    `init`, `erzeugen`, age-Schlüssel rotieren oder verloren.

-   :material-magnify-scan: **[Secret-Scan (gitleaks)](secret-scan.md)**

    ---

    Fund lesen, Fehlalarm erlauben, echten Fund behandeln.

-   :material-shield-search: **[Sicherheitsprüfung](security-scan.md)**

    ---

    Geheimnisse, Personendaten, trivy, kubeconform und Workflows in einem Lauf.

</div>

## Daten und Backups

<div class="grid cards" markdown>

-   :material-database-refresh-outline: **[Datenbank wiederherstellen](restore-database.md)**

    ---

    PITR und Desaster-Neuaufbau von `pg-lab`.

-   :material-source-repository: **[Gitea wiederherstellen](restore-gitea.md)**

    ---

    Desaster mit Datenbank und Dateien, versehentlich gelöschtes Repo.

-   :material-key-chain: **[Keycloak wiederherstellen](restore-keycloak.md)**

    ---

    Desaster-Neuaufbau von `keycloak-db`; Benutzer-IDs bleiben erhalten.

-   :material-database-import-outline: **[Gitea-Import](gitea-import.md)**

    ---

    Dump der Produktions-Forge ins Lab-Gitea einspielen (Repos und Benutzer), wiederholbar.

-   :material-database-import-outline: **[Matrix-Import](matrix-import.md)**

    ---

    Bestehenden Synapse mit Schlüssel, Konten, Räumen und Medien ins Lab-Matrix einspielen, wiederholbar.

-   :material-forum-outline: **[Matrix](matrix.md)**

    ---

    Synapse und Element Web im Lab: Föderation aus, Admin, Sicherung und Restore.

-   :material-key-chain: **[Keycloak (Single Sign-on)](keycloak.md)**

    ---

    Anmeldung für Gitea und Matrix über OIDC: Realm als Code, Notzugang, Sicherung und Restore.

-   :material-clipboard-check-outline: **[Gitea-Backup prüfen](verify-gitea-backup.md)**

    ---

    Das Restore-Verfahren in `verify-gitea.yml`.

-   :material-flash-alert-outline: **[Failover-Übung](failover-drill.md)**

    ---

    Primary töten, messen, auswerten.

-   :material-restore-alert: **[Restore-Test](restore-drill.md)**

    ---

    Gitea und Matrix nur aus den Backups wiederherstellen, gemessen.

-   :material-content-copy: **[Backup-Replikat](backup-replica.md)**

    ---

    Kopie der Backups auf einem zweiten Rechner, mit Vertrauensgrenze.

-   :material-bell-alert-outline: **[Alarm](alerts.md)**
-   :material-vpn: **[WireGuard-Tunnel](wireguard-tunnel.md)**

    ---

    Meldung bei Backup- oder Kantenausfall (Matrix, Desktop, Journal).

</div>

## Erweitern und veröffentlichen

<div class="grid cards" markdown>

-   :material-application-plus-outline: **[Neue App hinzufügen](add-app.md)**

    ---

    Namespace, Application, NetworkPolicy, Projekt.

-   :material-notebook-outline: **[Notiz-Sites](notes-sites.md)**

    ---

    Eine Liste, N passwortgeschützte Notizbuch-Sites.

-   :material-book-open-page-variant-outline: **[Doku-Site](docs-site.md)**

    ---

    Wie diese Seite gebaut, ausgeliefert und lokal ausprobiert wird.

-   :material-export: **[Öffentliche Fassung](public-release.md)**

    ---

    Export mit Wächter, damit keine persönlichen Werte hinausgehen.

-   :material-key-chain: **[Privates Secrets-Repo](private-secrets-repo.md)**

    ---

    Ciphertext getrennt vom öffentlichen Code, Neuaufbau ohne den eigenen Git-Server.

-   :material-github: **[Privater GitHub-Spiegel](github-push-mirror.md)**

    ---

    Push-Mirror mit Token für ein Repo, Deploy-Key nur lesend, vertrauter Commit für den Neuaufbau.

-   :material-source-branch-sync: **[Neuaufbau aus GitHub](neuaufbau-github.md)**

    ---

    Schalter `source: github`: das Lab abreissen und Argo CD aus dem Spiegel lesen lassen, mit Prüfung und Rückweg.

-   :material-usb-flash-drive: **[Notfall-Neuaufbau](notfall-neuaufbau.md)**

    ---

    Nur Rechner, GitHub und Stick: Notfall-Kit schreiben, alles wegstellen, aus GitHub neu bauen, Daten holen, sichern, wiederherstellen.

-   :material-draw-pen: **[SSH-Commit-Signatur](signed-commits.md)**

    ---

    Commits mit einem eigenen SSH-Signierschlüssel signieren, `allowed_signers`, Branch-Schutz in Gitea.

-   :material-source-merge: **[Alltag mit signierten Commits](alltag-signierte-commits.md)**

    ---

    Pull-Request testen, lokal neu signieren, per Fast-Forward nach `main`.

</div>
