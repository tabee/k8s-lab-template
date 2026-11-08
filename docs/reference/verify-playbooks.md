---
title: Verify-Playbooks
---

# Referenz: Verify-Playbooks

Vierzehn Ansible-Playbooks unter `ansible/` prüfen den Ist-Zustand. Sie laufen einzeln
oder gesammelt über `bash scripts/lab.sh acceptance`
([Abnahme-Prüfungen](acceptance-checks.md)). Fast alle sind **nur lesend**: sie
lesen mit `k8s_info`, `curl` und `kubectl --dry-run=server` und legen höchstens
Wegwerf-Objekte an, die sie am Ende wieder löschen. Von Geheimnissen lesen sie nur
Metadaten, nie Werte.

```bash
cd ansible
ansible-playbook <playbook>
```

| Playbook | Prüft | Hosts | Schreibt | Optionen |
|---|---|---|---|---|
| `verify.yml` | Härtung der VM: Firewall, SSH, sysctl, auditd, AppArmor, k3s | `k3s` | nur Wegwerf-Service und Testnetz (NodePort-Test) | `--tags sysctl`, `--tags nodeport` |
| `verify-argocd.yml` | Argo CD, Repo-Secret, Applications, Oberfläche über Traefik | `localhost` | nichts (PSA-Pod als Dry-Run) | |
| `verify-ksops.yml` | KSOPS, age-Secret, SOPS-Dateien im Repo | `localhost` | nichts | |
| `verify-traefik.yml` | Traefik, Weiterleitung, Header, NetworkPolicy | `localhost` | nichts | |
| `verify-certmanager.yml` | cert-manager, Lab-CA, nameConstraints, SniStrict | `localhost` | Wegwerf-Zertifikate `verify-nc-*` (block/always) | |
| `verify-public.yml` | öffentliche Probe (ACME DNS-01, `lab-acme`) | `localhost`, `k3s` | nichts | ohne `acme_*`: `SKIP` (Exit 0, kein Nachweis) |
| `verify-docs.yml` | Doku-Site im Cluster | `localhost` | nichts | |
| `verify-notes.yml` | Notiz-Sites | `localhost` | nichts | `-e verify_notes_only=<site>`; voller Login: `-e verify_notes_sso_user=<konto>` und `NOTES_SSO_PASSWORD` in der Umgebung |
| `verify-backup-s3.yml` | rustfs auf dem Steuerrechner | `backup_host`, `k3s`, `localhost` | Testobjekte (alle Versionen am Ende gelöscht), Prüf-Namespace | `-K`, `--skip-tags pod` |
| `verify-cnpg.yml` | CloudNativePG, Barman-Archiv, Restore-Test | `localhost` | Wegwerf-Cluster `<cluster>-verify` | `--tags repo`, `repo,cluster`, `backup`, `restore` |
| `verify-gitea.yml` | Gitea, `gitea-db`, K8up, Restore-Test | `localhost` | Dummy-Repo in Gitea, Wegwerf-Restore | `--tags repo`, `repo,cluster`, `restore` |
| `verify-matrix.yml` | Matrix: Föderation aus, Admin, `matrix-db`, K8up-Restore einer Markierung, Egress | `localhost` | Markierung im Medien-Store, Wegwerf-Namespace `matrix-verify` (danach gelöscht). Das Backup-Objekt `verify-<Lauf>` bleibt | `--tags repo`, `cluster`, `egress` |
| `verify-keycloak.yml` | Keycloak: Realm und OIDC-Discovery, Admin-Konsole von aussen zu, Anmeldequelle in Gitea, `keycloak-db` mit fertigem Backup, Egress | `localhost` | nichts (nur lesend und Proben-Pods mit Dry-Run) | `--tags repo`, `cluster`, `egress` |
| `verify-egress.yml` | Egress-NetworkPolicies: Erlaubtes verbindet, alles andere nicht | `localhost` | Wegwerf-Pods und ein Kontroll-Namespace (am Ende gelöscht) | |
| `verify-consistency.yml` | Kopien in `gitops/` gleich ihren Quellen (Gateway, CIDRs, S3-Port, Domain, Image-Pins, Branch) | `localhost` | nichts, braucht keinen Cluster | |
| `verify-alerts.yml` | Alarme: Timer, echte Prüfungen, nachgebauter Fehler alarmiert genau einmal, Senken | `backup_host` | Wegwerf-Konfiguration und -Zustand (am Ende gelöscht) | optional, `SKIP` ohne Installation |
| `restore-drill.yml` | Restore-Test: Gitea und danach Matrix aus den Backups, je in einem Wegwerf-Namespace, gemessen (nur über `lab.sh restore-drill`). Matrix steht in `restore-drill-matrix.yml` und läuft nur, wenn Gitea bestanden hat | `localhost` | Namespaces `<gitea>-drill` und `matrix-drill`, Einmal-Backups `drill-<Lauf>` (am Ende gelöscht). Das Objekt `verify-*` von Matrix bleibt | kein Teil der Abnahme |
| `verify-budget.yml` | Speicherbudget: Summe der echten Limits plus Reserve höchstens `memory_mib`, kein Container ohne Limit, `LimitRange`, kein Speicherdruck | `localhost` | nichts | |

## Tags der langen Prüfungen

`verify-cnpg.yml` und `verify-gitea.yml` kennen Tags, damit man schnell prüfen
kann:

| Aufruf | Wirkung | Dauer |
|---|---|---|
| `ansible-playbook verify-cnpg.yml` | alles, auch Restore-Test | etwa 10 Minuten |
| `ansible-playbook verify-cnpg.yml --tags repo` | nur das Repository, ohne Cluster (vor dem Commit) | Sekunden |
| `ansible-playbook verify-cnpg.yml --tags repo,cluster` | ohne Restore-Test: Gesundheit und Alter des letzten Backups | Sekunden |
| `ansible-playbook verify-gitea.yml` | alles, auch Restore-Test | etwa 10 Minuten |
| `ansible-playbook verify-gitea.yml --tags repo,cluster` | ohne Restore-Test | Sekunden |

Die Namen (Namespace, Cluster, ObjectStore, Pooler, Apps, Hosts) lesen die
Playbooks aus den Manifesten unter `gitops/`; das ist die einzige Stelle.
Endpoint und Buckets kommen aus `group_vars/all/backup_s3.yml`; die Kopien in
`objectstore.yaml` und `k8up-schedule.yaml` werden verglichen (Drift-Prüfung).

## Besonderheiten

- **Bootstrap braucht Zeit.** Die Applications sind nach dem Bootstrap nicht
  sofort bereit; die Prüfungen wiederholen mit Pausen.
- **Kein `/etc/hosts`-Eintrag nötig.** HTTPS-Prüfungen nutzen `curl --cacert`
  (Lab-CA) mit `--resolve`; die Host-Namen stehen im SNI/Host-Header.
- **PSA-Nachweis ohne Pod.**{#psa-nachweis} Ein unsicherer Pod wird per
  Server-Dry-Run geschickt und muss mit `violates PodSecurity` abgelehnt werden.
  Das tun neun Playbooks: `verify.yml` (privilegierter Pod im Namespace
  `default`), `verify-argocd.yml`, `verify-certmanager.yml`, `verify-docs.yml`,
  `verify-traefik.yml` und `verify-notes.yml` (je ein Test-Pod mit `check_mode: true`;
  bei `verify-notes.yml` einmal je Site in `tasks/verify-notes-site.yml`) sowie
  `verify-cnpg.yml` (Namespace der Datenbank und des Operators), `verify-ksops.yml`
  (Argo-CD- und cert-manager-Namespace) und `verify-public.yml` (Namespace der
  Probe), die die gemeinsame Aufgabe `ansible/tasks/psa-probe.yml` einbinden und
  die Namespaces in `verify_psa_namespaces` übergeben. Die Probe nutzt
  `ignore_errors: true` statt `failed_when: false`: die Prüfung liest `failed`
  und `msg` des Ergebnisses, und ab ansible-core 2.19 setzt `failed_when` beides
  zurück; die Zeile «...ignoring» in der Ausgabe ist erwartet. `verify-backup-s3.yml`
  und `verify-gitea.yml` prüfen PSA nicht ablehnend: Sie legen einen
  Wegwerf-Namespace mit `restricted` an und zeigen, dass ein konformer Pod dort läuft.
- **`verify-backup-s3.yml` braucht `-K`** (sudo für `ufw status` auf dem
  Steuerrechner). `lab.sh acceptance` fragt das Passwort einmal vorab.
- **`verify-public.yml` ist alles oder nichts**, sobald `acme_*` gesetzt
  ist: fünf Punkte (Issuer `lab-acme` ist Ready; Certificate `acme-probe` ist
  Ready und vom öffentlichen Issuer; der Probe-Name liegt **ausserhalb** der Lab-Domain;
  das Zertifikat nennt den Probe-Namen und stammt nicht von der Lab-CA; die VM
  vertraut ihm ohne `--cacert`).
- **Restore-Test (`verify-cnpg.yml`).** Testzeilen A schreiben, Zeitpunkt T
  merken, Testzeilen B schreiben, WAL archivieren, einen Wegwerf-Cluster bis T
  wiederherstellen (PITR). A muss gleich sein, B fehlen. Das letzte erfolgreiche
  Backup darf höchstens 26 Stunden alt sein.
- **Restore-Test (`verify-gitea.yml`).** Dummy-Repo anlegen, Datei committen,
  K8up-Backup, Repo löschen (204, danach 404), Restore, Vergleich von Commit und
  SHA-256 der Datei.

Die Ergebnisse der Läufe: [Abnahme-Messwerte](../how-to/acceptance.md).
