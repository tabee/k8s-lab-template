# Stufe 3: Härtung

!!! abstract "Lernpfad, Stufe 3"
    Runbook der Rollen `firewall`, der Erweiterungen in `base` und `k3s` sowie
    von `verify.yml`. Hier stehen keine Secrets. Die Seite bleibt als
    Lerngeschichte stehen; bei Abweichungen gelten die Seiten unter
    [Konzepte](../concepts/index.md) und [Referenz](../reference/index.md).
    Das Sicherheitsmodell steht in [Sicherheitsmodell](../concepts/security-model.md).

## Reihenfolge

1. VM-Snapshot auf dem Host (Rückweg für alles):
   `virsh snapshot-create-as k3s-lab vor-stufe3 --atomic`
2. Prüfen, ob `known_hosts` einen ed25519-Schlüssel für die VM hat (der
   Server bietet danach kein ECDSA mehr an):
   `ssh-keygen -F 192.168.122.50 | grep ed25519`
3. Check-Lauf: `ansible-playbook site.yml --check --diff`
4. Echter Lauf: `ansible-playbook site.yml`
5. Zweiter Lauf (Idempotenz): `ansible-playbook site.yml` muss changed=0 zeigen.
   Die auditd-Watches für k3s-Pfade zieht `site.yml` seit dem Lab-Neuaufbau
   (2026-10-30) schon im ersten Lauf nach (post_tasks).
6. `ansible-playbook verify.yml`. Eine frische VM startet direkt mit secretbox
   (Stage `start`, nur ein Schlüssel), da ist nichts zu migrieren. Die
   secretbox-Migration unten braucht es nur für eine VM, die noch mit
   AES-CBC läuft.

## Firewall: Schutz vor Aussperren

- Die Rolle bricht ab, wenn die SSH-Absender-IP nicht in `firewall_admin_cidrs` liegt.
- Jede Regeldatei wird vor dem Schreiben mit `nft -c -f` geprüft.
- Totmannschalter: vor dem Laden startet `systemd-run` einen Timer
  (`firewall_rollback_seconds`, 120 s). Läuft er ab, löscht er die Tabelle
  `inet host_filter` und deaktiviert `nftables.service` (auch ein Neustart
  sperrt dann nicht wieder aus). Ansible stoppt ihn erst, wenn eine NEUE
  SSH-Verbindung klappt.
- Notzugang ohne SSH (Passwort ist gesperrt, `virsh console` hilft nicht),
  über den qemu-guest-agent, falls `guest-exec` erlaubt ist:
  `virsh qemu-agent-command k3s-lab '{"execute":"guest-exec","arguments":{"path":"/usr/sbin/nft","arg":["delete","table","inet","host_filter"]}}'`
  Gleiches Muster für `/usr/bin/systemctl` mit `["restart","ssh.socket"]`.
- Letzter Ausweg: `virsh snapshot-revert k3s-lab vor-stufe3`.

Warum kein `flush ruleset`: Ubuntu legt `/etc/nftables.conf` mit
`flush ruleset` an und `nftables.service` hat `ExecStop=/usr/sbin/nft flush ruleset`.
Beides würde die Tabellen von kube-proxy/flannel/Network-Policy löschen
(Pod-Netz und Services tot bis zum k3s-Neustart). Darum: include-only
`/etc/nftables.conf` und Drop-in mit `ExecStop=` nur für die eigene Tabelle.

Warum keine Forward-Chain mit `policy drop`: Pod-zu-Pod, Pod-nach-aussen und
Antworten laufen durch FORWARD und werden von k3s (kube-proxy, flannel,
kube-router) verwaltet. Eine eigene Chain mit `policy drop` müsste jede dieser
Regeln nachbauen und bricht das Cluster-Netz bei jeder Änderung. Die
Forward-Chain der Rolle hat darum `policy accept` und sperrt nur gezielt
(nächster Abschnitt).

## Netz-Kante: NodePorts zu, Profil edge

!!! info "Umgezogen"
    Seit den [Issues 1](https://github.com/tabee/k8s-lab-template/issues/1) und [2](https://github.com/tabee/k8s-lab-template/issues/2) steht die Netz-Kante an drei Stellen, die
    heute gelten:

    - Erklärung (Chains, Warum, Grenzen): [Netz-Kante](../concepts/network-edge.md)
    - Anleitung (Profil `edge` ausprobieren und zurück, Abnahme): [Edge-Profil schalten](../how-to/edge-profile.md)
    - Werte (`edge_profile`, `edge_admin_cidrs`, `edge_ingress_cidrs`, `edge_profile_admin`): [Konfiguration](../reference/configuration.md)

    Ports und Netze auf einen Blick: [Ports und Netze](../reference/ports-and-networks.md).

## secretbox-Migration (manuell, einmalig)

Quelle: https://docs.k3s.io/security/secrets-encryption (Migrating Providers)
und https://docs.k3s.io/cli/secrets-encrypt (Encryption Key Rotation).
Geprüft am k3s-Quellcode v1.36.5+k3s1:
- Beim Start mit `secrets-encryption-provider: secretbox` bleibt eine
  vorhandene `encryption-config.json` unverändert (AES-CBC bleibt aktiv, nichts bricht).
- `rotate-keys` legt einen secretbox-Schlüssel an, stellt ihn an die erste
  Stelle, verschlüsselt alle Secrets neu und entfernt danach den
  AES-CBC-Schlüssel (`pkg/server/handlers/secrets-encrypt.go`).
- `prepare/rotate/reencrypt` gehen mit secretbox NICHT, nur `rotate-keys`.

Ablauf auf der VM (nach `site.yml`):

```bash
# 1) Starting point: enabled, active key AES-CBC, stage start or reencrypt_finished
sudo k3s secrets-encrypt status

# 2) Backup (contains keys! never commit it, delete after success)
sudo systemctl stop k3s
sudo tar -C / -czf /root/k3s-vor-secretbox.tgz \
  var/lib/rancher/k3s/server/db var/lib/rancher/k3s/server/cred \
  var/lib/rancher/k3s/server/token etc/rancher/k3s
sudo chmod 600 /root/k3s-vor-secretbox.tgz
sudo systemctl start k3s
# (alternatively or additionally: VM snapshot on the host)

# 3) Rotation with re-encryption (about 5 secrets per second)
sudo k3s secrets-encrypt rotate-keys

# 4) Wait until finished
watch -n 2 sudo k3s secrets-encrypt status
#   Current Rotation Stage: reencrypt_finished
#   active key (*): XSalsa20-POLY1305 secretboxkey-...

# 5) Counter-check
sudo k3s kubectl get secrets -A >/dev/null && echo readable
sudo systemctl restart k3s   # prove a start with the new config once

# 6) Remove the backup when everything runs
sudo shred -u /root/k3s-vor-secretbox.tgz
```

Rückweg: Bricht die Rotation ab, enthält die Konfiguration beide
Schlüssel (k3s speichert vor dem Neuverschlüsseln), `systemctl restart k3s`
reicht meist. Sonst Sicherung zurückspielen (k3s gestoppt) oder Snapshot.

## Bewusst NICHT umgesetzt

- EventRateLimit (CIS 1.2.9): Admission-Plugin mit Alpha-API
  (`eventratelimit.admission.k8s.io/v1alpha1`), Single-User-Lab ohne Nutzen.
- `-e 2` in auditd: Regeln wären bis zum Neustart unveränderlich.
- Exec-Logging aller Prozesse: Containerlast erzeugt zu viel Rauschen.
- chmod 600 auf `server/tls/*.crt` (CIS 1.1.20): k3s legt sie neu an; im
  Guide als manuelle Kontrolle geführt.

## Abschluss (2026-10-23)

- secretbox-Migration via `k3s secrets-encrypt rotate-keys` erfolgreich;
  aktiver Schlüssel `XSalsa20-POLY1305`, Stage `reencrypt_finished`.
- Backup `/root/k3s-vor-secretbox.tgz` mit `shred -u` vernichtet.
- `ansible-playbook verify.yml`: ok=32 changed=0 failed=0.
- Snapshots `nach-stufe3-vor-secretbox` und `vor-secretbox` gelöscht,
  `vor-stufe3` bleibt als Rückweg bis Argo CD läuft.

## Nachtrag (2026-10-26): sysctl-Werte überleben den Neustart

**Was war:** Nach einem Neustart der VM meldete `verify.yml`
`fs.suid_dumpable: erwartet 0, ist 2` und `fs.protected_fifos: erwartet 2, ist 1`.
`site.yml` hatte die Werte bei jedem Lauf zur Laufzeit wieder richtig
gesetzt, darum fiel es erst nach einem Reboot auf.

**Warum:** zwei Ursachen.

1. Reihenfolge der Dateien. `systemd-sysctl` liest beim Boot `/etc/sysctl.d`,
   `/run/sysctl.d`, `/usr/local/lib/sysctl.d` und `/usr/lib/sysctl.d`
   gemeinsam, sortiert nach **Dateiname** (nicht nach Verzeichnis). Gleicher
   Name in `/etc` ersetzt die Datei in `/usr/lib`. Der letzte Wert gewinnt.
   `80-hardening.conf` kam vor `/usr/lib/sysctl.d/99-protect-links.conf`
   (procps, setzt `fs.protected_fifos = 1`).
2. `apport.service` startet nach `systemd-sysctl` und schreibt
   `fs.suid_dumpable=2` und `kernel.core_pattern=|/usr/share/apport/apport ...`.
   Gegen einen Dienst hilft keine sysctl.d-Datei.

**Wie:**

- Die Dateien heissen neu `99-zz-k8s.conf` und `99-zz-hardening.conf`
  (Variablen `base_sysctl_file`, `base_sysctl_hardening_file` in
  `group_vars/all/main.yml`). `99-zz-` sortiert nach allen 99er-Dateien von
  Ubuntu (`99-cloudimg-ipv6.conf`, `99-protect-links.conf`,
  `99-sysctl.conf` = `/etc/sysctl.conf`). Die alten Dateien
  (`base_sysctl_old_files`) löscht die Rolle, nachdem die neuen geschrieben sind.
- `90-k8s.conf` zieht mit um: gleiche Falle, z.B. würde ein
  `net.ipv4.ip_forward=0` in `/etc/sysctl.conf` das Pod-Netz nach dem
  Reboot abschalten. Jeder Schlüssel steht nur in einer Datei (die Rolle
  prüft das).
- apport: stoppen, deaktivieren, maskieren (`roles/base/tasks/apport.yml`).
  Stoppen zuerst, denn `ExecStop` (`apport --stop`) setzt `suid_dumpable=0`
  und `core_pattern=core` zurück; nach dem Maskieren ginge das nicht mehr.
- `verify.yml` prüft neu auch den Boot-Zustand: es liest
  `systemd-sysctl --cat-config` (genau die Dateien in der Boot-Reihenfolge),
  nimmt je Schlüssel die letzte Zuweisung und vergleicht. Dazu: apport
  maskiert, `kernel.core_pattern` ohne apport.

**Entscheid apport: maskieren statt purge**

| | maskieren | purge |
|---|---|---|
| Abhängigkeiten | keine Paketänderung | nimmt `ubuntu-server`, `ubuntu-server-minimal`, `apport-core-dump-handler` mit; deren Abhängigkeiten werden autoremove-Kandidaten |
| Paket-Update | Maske bleibt (`deb-systemd-helper unmask` entfernt nur eigene Masken, `deb-systemd-invoke` startet nichts Maskiertes) | kommt mit einem Metapaket zurück, braucht Pin |
| apport fehlt | Maske greift trotzdem, auch bei späterer Installation | nichts zu tun |
| Rückweg | `systemctl unmask apport.service` | neu installieren |

**Selber nachsehen (auf der VM):**

```bash
/usr/lib/systemd/systemd-sysctl --cat-config | grep -e '^# /' -e protected_fifos -e suid_dumpable
systemctl is-enabled apport.service   # masked
sysctl fs.suid_dumpable fs.protected_fifos kernel.core_pattern
```

**Reboot-Test (vom Laptop, im Ordner `ansible/`):**

```bash
ansible k3s -b -m ansible.builtin.reboot -a reboot_timeout=600
ansible-playbook verify.yml --tags sysctl
# k3s needs a moment after the start, then everything:
ansible-playbook verify.yml
```

**Eselsbrücke:** *"Beim Boot spricht zuletzt, wer hinten im Alphabet steht,
und apport redet danach, darum: zz in den Namen, apport die Maske auf."*
