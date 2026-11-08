---
title: Der Lab-CA vertrauen
---

# Der Lab-CA vertrauen

**Ziel:** Browser und Werkzeuge auf deinen Geräten akzeptieren die Zertifikate
des Labs (`https://argocd.lab.example`, `https://git.lab.example`, …).

**Voraussetzungen:** das Lab läuft (`lab.sh up`); die öffentliche CA-Datei
`~/.config/k8s-lab/lab-ca.crt` existiert (Ansible legt sie in `argocd.yml` ab).

!!! warning "Nur die öffentliche Datei verteilen"
    Verteile `lab-ca.crt`, **nie** das Secret der CA oder deren Schlüssel.
    Prüfe den Fingerabdruck auf dem Zielgerät gegen den auf dem Steuerrechner:

    ```bash
    openssl x509 -in ~/.config/k8s-lab/lab-ca.crt -noout -fingerprint -sha256
    ```

Was die CA darf, begrenzt die [Namenseinschränkung](../concepts/certificates.md#namenseinschraenkung-der-lab-ca):
nur Namen unter der Lab-Domain.

=== "Linux"

    Firefox und Chromium vorher schliessen.

    ```bash
    # add: system store + NSS databases of Firefox and Chromium
    ansible/scripts/lab-ca-trust.sh add ~/.config/k8s-lab/lab-ca.crt
    # undo
    ansible/scripts/lab-ca-trust.sh remove ~/.config/k8s-lab/lab-ca.crt
    ```

    - **System-Store** (curl, wget, Python): Debian/Ubuntu
      `/usr/local/share/ca-certificates` plus `update-ca-certificates`;
      Fedora/Arch `/etc/pki/ca-trust/source/anchors` plus `update-ca-trust`
      (braucht sudo).
    - **Chromium/Chrome:** NSS-Datenbank `~/.pki/nssdb` (Paket
      `libnss3-tools` beziehungsweise `nss-tools` für `certutil`).
    - **Firefox:** eigene NSS-Datenbank pro Profil (auch Snap und Flatpak). Das
      Skript trägt die CA in jedes gefundene Profil ein. Von Hand:
      Einstellungen › Datenschutz › Zertifikate › Importieren, nur „Websites
      identifizieren“ anhaken.

=== "Android"

    Einstellungen › Sicherheit › Verschlüsselung und Anmeldedaten ›
    Zertifikat installieren › CA-Zertifikat.

    Grenze: Seit Android 7 vertrauen Apps Nutzer-CAs nur, wenn die App das
    erlaubt. Chrome und Firefox (mit „Drittanbieter-CA“ in den Einstellungen)
    funktionieren, viele Apps (zum Beispiel Gitea-Clients) nicht. Eine
    System-CA geht nur mit Root.

=== "iPhone/iPad"

    Datei per AirDrop oder Mail senden, das Profil installieren, dann
    Einstellungen › Allgemein › Info › Zertifikatsvertrauenseinstellungen ›
    für die Lab-CA einschalten.

!!! note "HSTS"
    Traefik sendet HSTS. Sobald ein Browser der CA vertraut, merkt er sich
    „nur HTTPS“ für den Namen. Ein später ungültiges Zertifikat lässt sich
    dann nicht mehr wegklicken.

**Prüfen:** `curl https://argocd.lab.example/` ohne `--cacert` antwortet, und
der Browser zeigt kein Warnsymbol. Wechselt die CA ([Rotation](ca-rotation.md)),
vorher `remove`, danach `add`.
