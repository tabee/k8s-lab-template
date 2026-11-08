---
title: "ADR-0005: Host-Firewall mit Prüfung am Original-Zielport"
---

# ADR-0005: Host-Firewall mit Prüfung am Original-Zielport

**Status:** angenommen

## Kontext

k3s leitet Verkehr für NodePorts und hostPorts per DNAT an Pods. Dieser Verkehr läuft durch die Kette `forward`, nicht durch `input`. Eine dichte Input-Kette lässt den Weg offen.

## Entscheidung

Eine eigene Tabelle `inet host_filter` mit Policy `drop` in `input` und einer `forward`-Kette (Policy `accept`), die neue DNAT-Verbindungen von aussen anhand `ct original proto-dst` prüft: 80 und 443 nur aus Ingress- und Admin-Netz, alles andere nur aus dem Admin-Netz. Die Tabelle wird atomar ersetzt; **nie** `flush ruleset`, weil das die Regeln von k3s und kube-router mitlöschen würde. Ein Totmann-Timer (120 s) rollt eine Änderung zurück, wenn die eigene SSH-Verbindung nicht mehr geht.

## Folgen

Wer die Firewall ändert, kann sich aussperren; der Timer fängt das ab. Die Ketten sind getestet (`verify.yml --tags nodeport`), aber nur auf dem Lab-Netz, nicht auf einer öffentlichen Karte.

## Siehe auch

[Netz-Kante](../network-edge.md)
