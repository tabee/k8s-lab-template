---
title: "ADR-0003: Wiederholungen statt Sync-Waves zwischen Apps"
---

# ADR-0003: Wiederholungen statt Sync-Waves zwischen Apps

**Status:** angenommen

## Kontext

Apps hängen voneinander ab (zum Beispiel braucht Gitea seine Datenbank, die Datenbank das Plugin, das Plugin cert-manager).

## Entscheidung

Es gibt **keine** Sync-Waves zwischen Apps. Jede Application hat `automated` mit `prune` und `selfHeal` sowie eine Wiederholung mit Backoff (5 oder 10 Versuche). Sync-Waves gibt es nur innerhalb von Apps (Namespaces mit Wave `-1`, cert-manager-Manifeste mit Wave `1`, das Plugin-Deployment in `cnpg` mit Wave `1` hinter seinen Zertifikaten, siehe [Fehlersuche](../../how-to/troubleshooting.md#restore-plugin-tls)).

## Folgen

Ein frischer Aufbau zeigt kurzzeitig `Degraded` oder `OutOfSync`, bis alle Abhängigkeiten stehen. Der Neuaufbau am 2026-10-30 dauerte 23 min 36 s, davon der Argo-Sync 18 min 59 s. Bei zu knappen Wiederholungen bleibt eine App hängen; die Grenzen stehen in `gitops/apps/*.yaml`.

## Siehe auch

[Bootstrap und GitOps](../bootstrap-and-gitops.md#sync-waves-und-reihenfolge-was-wirklich-gilt)
