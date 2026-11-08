---
title: Entscheidungen (ADR)
---

# Entscheidungen (ADR)

Architekturentscheidungen als kurze Datensätze: **Kontext, Entscheidung, Folgen**. Sie halten fest, was gilt und warum, damit niemand es aus dem Code zurückrechnen muss. Die Stufenseiten im [Lernpfad](../../learning-path/index.md) enthalten die ausführlichen Tabellen „Entscheidungen“ je Baustein.

Status aller Einträge: **angenommen**. Eine Änderung wird als neuer Eintrag geschrieben, der den alten ersetzt; der alte bleibt stehen.

| Nr. | Entscheidung |
|---|---|
| 0001 | [Eine Quelle für alle Werte](0001-one-source-lab-yaml.md) |
| 0002 | [OpenTofu baut das Haus, Ansible richtet es ein](0002-tofu-and-ansible.md) |
| 0003 | [Wiederholungen statt Sync-Waves zwischen Apps](0003-retries-instead-of-sync-waves.md) |
| 0004 | [SOPS/age mit KSOPS für Geheimnisse im Git](0004-sops-age-ksops.md) |
| 0005 | [Host-Firewall mit Prüfung am Original-Zielport](0005-nftables-forward-check.md) |
| 0006 | [Traefik mit `externalTrafficPolicy: Cluster`](0006-traefik-traffic-policy-cluster.md) |
| 0007 | [Lab-CA mit nameConstraints und getrenntem öffentlichem Issuer](0007-lab-ca-name-constraints.md) |
| 0008 | [Backup ausserhalb der VM, ein Primärziel](0008-backup-outside-vm.md) |
| 0009 | [Neuaufbau ist ein sauberer Start, kein Restore](0009-rebuild-is-clean-start.md) |
| 0010 | [Diagramme: Mermaid selbst ausgeliefert, Quelltext als Rückfall](0010-mermaid-cdn.md) |
| 0011 | [Doku mit Zensical, im Cluster gebaut](0011-zensical-docs-cluster-build.md) |
| 0012 | [Öffentliche Kopie per Export mit Wächter](0012-public-export.md) |
| 0013 | [Backup-Replikat mit rsync und rrsync](0013-replica-rsync-rrsync.md) |
| 0014 | [Restore-Test im Wegwerf-Namespace](0014-restore-drill-throwaway-namespace.md) |
| 0015 | [Gitea-Import per gitea dump](0015-gitea-import-dump.md) |
| 0016 | [Matrix ohne Föderation, eine Quelle für server_name](0016-matrix-federation-off.md) |
| 0017 | [VM erst stoppen, wenn das End-WAL im Archiv liegt](0017-wal-before-vm-stop.md) |
| 0018 | [Wiederherstellung nur zur Laufzeit](0018-recover-from-backup.md) |
| 0019 | [Keycloak als Single Sign-on](0019-keycloak-sso.md) |
| 0020 | [Matrix-Import per Datenbank-Dump und Schema-Tausch](0020-matrix-import.md) |
| 0021 | [Notiz-Sites hinter Keycloak](0021-notes-sso.md) |
| 0022 | [Privates Secrets-Repo neben dem öffentlichen Code-Repo](0022-private-secrets-repo.md) |
| 0023 | [Signierte Commits auf main und Quellvertrauen beim Neuaufbau](0023-signed-main-and-source-trust.md) |
| 0024 | [GitHub als schaltbare Quelle von Argo CD](0024-github-as-switchable-source.md) |
| 0025 | [Notfall-Kit auf einem USB-Stick](0025-emergency-kit.md) |
| 0026 | [Kernbetrieb von optionalen Sites trennen](0026-unattended-recovery.md) |
| 0027 | [Mehrere Umgebungen, ein Quelltext](0027-environments-one-source.md) |
| 0028 | [Externer Heartbeat statt dauerhaftem Heim-Gegenpunkt](0028-external-heartbeat.md) |
| 0029 | [Import-Belege ausserhalb des Clusters](0029-import-evidence-after-restore.md) |
| 0030 | [Gitea Actions mit Job-Pods statt Docker-in-Docker](0030-gitea-actions-runner.md) |

## Vorlage

```markdown
# ADR-NNNN: Titel

**Status:** vorgeschlagen | angenommen | ersetzt durch ADR-MMMM

## Kontext
## Entscheidung
## Folgen
## Siehe auch
```
