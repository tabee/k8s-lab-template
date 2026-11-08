---
title: WireGuard-Tunnel zur Produktion
---

# WireGuard-Tunnel zur Produktion

**Ziel:** SSH und die Kubernetes-API der Produktion laufen nur noch im Tunnel, und das Backup-S3
auf dem Steuerrechner ist nur über die Tunnel-Schnittstelle erreichbar. Umsetzung von
[Issue 60](https://github.com/tabee/k8s-lab-template/issues/60).

**Was / Warum.** Der öffentliche Port 22 und 6443 sind nur für die Bootstrap-Phase offen. Sobald
der Tunnel steht, gehören Admin-Zugriff und Backup-Pfad dem Tunnelnetz. Ohne Ansible-Rolle bleibt
der Tunnel Handarbeit; die Rolle `wireguard` richtet Server (Knoten) und Client (Steuerrechner)
gleich ein.

**Eselsbrücke:** «Zuerst der Tunnel, dann die Haustür zu.»

## Voraussetzungen

1. `wireguard_enabled: true` in der Prod-Inventargruppe (liegt im Prod-Zweig der Infrastruktur,
   nicht in der Lab-Standardkonfiguration).
2. Tunneladressen, AllowedIPs, Listen-Port und Endpoint sind in der Prod-Inventargruppe gesetzt
   (`wireguard_address_server`, `wireguard_address_client`, `wireguard_allowed_ips_*`,
   `wireguard_endpoint`). Die Lab-Werte bleiben leer.
3. Schlüsselpaar je Seite, Kind `wireguard` in der Geheimnis-Karte, nie im Git. Der Playbook-Lauf
   legt fehlende Schlüssel selbst an. Nur ansehen, nie Werte:

```bash
bash scripts/lab.sh secrets | sed -n "/wireguard/,+5p"
```

Die öffentliche Seite liegt neben dem privaten Schlüssel als `.pub` (Modus 644). Die Rolle liest
nur die `.pub` der Gegenseite und kopiert den privaten Schlüssel nach `/etc/wireguard/wg0.key`
(Modus 600). Die Konfigurationsdatei enthält den privaten Schlüssel **nicht**.

## Einrichten

```bash
# Syntax only (safe anywhere):
(cd ansible && ansible-playbook --syntax-check wireguard.yml site.yml)

# Live (needs sudo on the node and on the control PC; dead man's switch 120 s on firewall changes):
(cd ansible && ANSIBLE_INVENTORY=inventory/prod.yml ansible-playbook wireguard.yml -K)
```

Danach prüfst du den Handshake und schliesst die öffentliche Admin-Freigabe (siehe
den Runbook-Schritt «Tunnel und Kante schliessen» der Produktionsumgebung).

```bash
sudo wg show
```

## Grenzen

- Der Tunnel ersetzt **nicht** den externen Heartbeat ([Alarme](alerts.md), ADR 0028). Die
  Überwachung bleibt beim externen Ping; der Steuerrechner ist kein dauerhafter Alarm-Gegenpunkt.
- Solange der Steuerrechner aus ist, laufen keine Sicherungen auf das Heim-S3. Das ist Absicht.
- Live-Anwenden gehört in die Prod-Umgebung; dieses How-to beschreibt nur den Ablauf. Nichts davon
  wird hier ausgelöst.

## Siehe auch

- [Alarm bei Backup- oder Kantenausfall](alerts.md)
- ADR 0028
