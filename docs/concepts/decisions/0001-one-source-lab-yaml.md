---
title: "ADR-0001: Eine Quelle für alle Werte"
---

# ADR-0001: Eine Quelle für alle Werte

**Status:** angenommen

## Kontext

Ohne gemeinsame Quelle stehen Adressen, Namen, Netze und Pfade in OpenTofu, Ansible, `lab.sh` und den GitOps-Manifesten getrennt. Sie laufen auseinander.

## Entscheidung

`infra/envs/local/lab.yaml` ist die Quelle, `lab.local.yaml` (nicht im Git) überschreibt einzelne Schlüssel. OpenTofu liest beide in `locals.tf`, Ansible in `group_vars/all/lab.yml` (Variable `lab`), `scripts/lab.sh` in seinem Parser. Ein unbekannter Schlüssel in `lab.local.yaml` bricht ab. Werte, die Argo CD nicht aus Ansible lesen kann (Gateway, CIDRs, S3-Endpoint), stehen als Kopie in `gitops/`; `verify-*.yml` vergleichen Kopie und Quelle und brechen bei Abweichung ab.

## Umgebungen

Weitere Umgebungen (`infra/envs/<name>/lab.yaml`) überschreiben nur ihre Abweichungen; Aufbau und Regeln stehen in [ADR-0027](0027-environments-one-source.md).

## Folgen

Ein Freund ändert eine Datei und baut das Lab im eigenen Netz. Kopien in `gitops/` bleiben eine Fehlerquelle; jede neue Kopie braucht einen Vergleich im Verify ([Issue 10](https://github.com/tabee/k8s-lab-template/issues/10)).

## Siehe auch

[Konfiguration](../../reference/configuration.md)
