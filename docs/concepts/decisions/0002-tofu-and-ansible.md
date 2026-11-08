---
title: "ADR-0002: OpenTofu baut das Haus, Ansible richtet es ein"
---

# ADR-0002: OpenTofu baut das Haus, Ansible richtet es ein

**Status:** angenommen

## Kontext

Eine VM entsteht anders, als sie konfiguriert wird. Wer beides in einem Werkzeug mischt, kann das Haus nicht mehr abreissen, ohne Zustand zu verlieren.

## Entscheidung

OpenTofu (`infra/`, Provider `dmacvicar/libvirt` 0.9.9) legt nur Volumes (Basis-Image, Platte, cloud-init-Seed), die cloud-init-Disk und die libvirt-Domain an; es nutzt keine Provisioner. Ansible (`ansible/`) richtet Host, Firewall, k3s und die Bootstrap-Schritte für Argo CD ein. Danach übernimmt Git.

## Folgen

`down` kann nur das Haus abreissen (`tofu destroy` mit Vorbedingung); Werkzeugschuppen (rustfs, Schlüssel, Repo) bleiben stehen. Ein von Hand zurückgespielter Export ist OpenTofu unbekannt: erst `purge`, dann `up`.

## Siehe auch

[Bootstrap und GitOps](../bootstrap-and-gitops.md), [Neuaufbau](../../how-to/rebuild.md)
