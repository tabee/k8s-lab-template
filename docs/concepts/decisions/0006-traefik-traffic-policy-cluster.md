---
title: "ADR-0006: Traefik mit `externalTrafficPolicy: Cluster`"
---

# ADR-0006: Traefik mit `externalTrafficPolicy: Cluster`

**Status:** angenommen

## Kontext

Mit `Local` bräuchte der ServiceLB von k3s NodePorts, und diese umgehen die Forward-Prüfung. Mit `Cluster` sieht Traefik die Client-Adresse nicht.

## Entscheidung

`externalTrafficPolicy: Cluster` und `allocateLoadBalancerNodePorts: false`. `loadBalancerSourceRanges` spiegelt `edge_ingress_cidrs`; `verify-traefik.yml` vergleicht `lab.yaml`, Git und den Service.

## Folgen

Die Client-IP fehlt im Access-Log (Restrisiko R7). Die Allow-List sitzt in der Host-Firewall, nicht im Proxy.

## Siehe auch

[Stufe 5](../../learning-path/stage-5-traefik.md)
