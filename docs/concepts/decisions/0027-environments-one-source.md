---
title: "ADR-0027: Mehrere Umgebungen, ein Quelltext"
---

# ADR-0027: Mehrere Umgebungen, ein Quelltext

**Status:** vorgeschlagen

## Kontext

Das Lab läuft als VM auf dem Steuerrechner (`infra/envs/local`). Dieselbe Plattform soll auch auf einem
gemieteten Server laufen, der einen Dienst im Internet ersetzt. Zwei Kopien des Codes würden auseinanderlaufen
(zwei `site.yml`, zwei Rollen). [ADR-0001](0001-one-source-lab-yaml.md) verlangt eine Quelle je Wert.

## Entscheidung

1. **Eine Umgebung ist ein Ordner** `infra/envs/<name>/` mit nur den abweichenden Werten (`lab.yaml`) und der
   eigenen, nicht eingecheckten Datei `lab.local.yaml`. Die Basis bleibt `infra/envs/local/lab.yaml`. Die Ebenen
   werden zusammengelegt: Basis, dann Umgebung, dann `lab.local.yaml` der Umgebung. Ein Wert steht dort, wo er
   sich unterscheidet, sonst nur in der Basis.
2. **OpenTofu und Ansible lesen dieselben Ebenen.** OpenTofu je Umgebung in `locals.tf`. Ansible über die Variable
   `lab_env` (nur im Inventar der Umgebung gesetzt, ohne Wert gilt `local`); `group_vars/all/lab.yml` legt die Ebenen
   zusammen. Für die Umgebung `local` ist das Ergebnis Byte für Byte dasselbe wie vorher.
3. **Gemeinsame Bausteine statt Kopien.** Was mehrere Umgebungen brauchen, steht in einem Modul:
   `infra/modules/cloud-init` erzeugt die Erstkonfiguration für jede Umgebung, `infra/modules/libvirt-vm` baut die
   lokale VM. Playbooks und Rollen gibt es nur einmal.
4. **Eigene Geheimnisse einer Umgebung** stehen in `group_vars/<umgebung>/secrets.yml` (Liste `secrets_<umgebung>`)
   und werden zur gemeinsamen Karte `secrets_all` addiert. Die Geheimnis-Karte bleibt die eine Liste.
5. **Zustand getrennt.** Jede Umgebung hat einen eigenen Bucket und einen eigenen Zugang für den OpenTofu-Zustand.
   Ein Fehler in einer Umgebung kann den Zustand der anderen nicht anfassen.
6. **Das Netz folgt denselben Listen.** Die Firewall des Anbieters leitet sich aus `edge_admin_cidrs` und
   `edge_ingress_cidrs` ab, die auch die nftables auf dem Knoten steuern. Private Adressen (Tunnel) öffnen dort nie
   einen Port. Zugriff ohne Tunnel gibt es nur über eine öffentliche Adresse, die der Besitzer selbst einträgt.
7. **Löschen ist doppelt gesichert.** Server und feste Adresse tragen `prevent_destroy` und den Löschschutz des
   Anbieters. Der Apply-Schritt des Umgebungsskripts bricht ab, wenn der Plan etwas löscht oder ersetzt.

8. **Prod-Branch statt Overlays (Übergang).** Solange Issue #96 (Public Export, Overlay-Umbau) offen ist,
   erzeugt `bash scripts/prod.sh render-gitops` zusammen mit `customize` einen lokalen Branch `prod`: ohne
   `whoami`/`db-lab`, mit den Prod-Bucket-Namen und `targetRevision: prod`. Der Branch wird nie von Hand
   editiert und von diesem Workflow nicht auf dem Remote angelegt. Argo CD in der Produktion liest genau
   diesen Branch (`argocd_repo_revision: prod`).

## Folgen

- Eine neue Umgebung ist ein Ordner, ein Inventar und eine Zeile in der Ausnahmeliste, kein neuer Code.
- Jeder neue Schlüssel in der Basis gilt automatisch für alle Umgebungen; ein unbekannter Schlüssel in einer
  Umgebung bricht ab.
- Die Befehle von `lab.sh` lesen weiter nur die lokale Umgebung. Für andere Umgebungen gibt es ein eigenes Skript,
  damit `lab.sh` nicht zwei Wahrheiten kennt.
- Umgebungsspezifische Dateien können vom öffentlichen Export ausgenommen werden ([ADR-0012](0012-public-export.md)),
  ohne dass der gemeinsame Code Namen des Anbieters trägt.

## Siehe auch

[ADR-0001](0001-one-source-lab-yaml.md), [ADR-0002](0002-tofu-and-ansible.md), [Konfiguration](../../reference/configuration.md)
