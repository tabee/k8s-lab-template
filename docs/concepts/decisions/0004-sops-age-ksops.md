---
title: "ADR-0004: SOPS/age mit KSOPS für Geheimnisse im Git"
---

# ADR-0004: SOPS/age mit KSOPS für Geheimnisse im Git

**Status:** angenommen

## Kontext

Argo CD liest nur das Git. Geheimnisse müssen deshalb verschlüsselt im Git liegen oder ausserhalb entstehen.

## Entscheidung

SOPS mit age verschlüsselt `data` und `stringData`; KSOPS (v4.5.1) entschlüsselt im `argocd-repo-server`. Ein Secret pro Datei, ein Ordner pro Namespace, eine App pro Ordner. Argo CD legt an, löscht nie (`Prune=false,Delete=false`). Was Argo CD selbst zum Lesen braucht (age-Schlüssel, Deploy-Key), legt Ansible an. Passwörter, die nur ein Operator braucht (zum Beispiel das Postgres-App-Passwort), erzeugt der Operator im Cluster und nicht KSOPS.

## Folgen

Der Entschlüsselungsschlüssel liegt im Cluster (Restrisiko R2, [Issue 11](https://github.com/tabee/k8s-lab-template/issues/11)). Es gibt eine Karte aller Geheimnisse und einen einzigen Erzeuger (`lab.sh init`).

## Siehe auch

[Geheimnisfluss](../secret-flow.md)
