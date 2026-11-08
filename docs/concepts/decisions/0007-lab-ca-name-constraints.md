---
title: "ADR-0007: Lab-CA mit nameConstraints und getrenntem öffentlichem Issuer"
---

# ADR-0007: Lab-CA mit nameConstraints und getrenntem öffentlichem Issuer

**Status:** angenommen

## Kontext

Eine CA, die jeden Namen signieren darf, ist ein Risiko für jedes Gerät, das ihr vertraut.

## Entscheidung

Die Lab-CA trägt kritische `nameConstraints` (nur DNS-Namen unter der Lab-Domain, keine IPs). Eine ValidatingAdmissionPolicy lehnt Certificates über `lab-ca` für fremde Namen ab. Für Namen ausserhalb der Lab-Domain gibt es den zweiten ClusterIssuer `lab-acme` (DNS-01), nur wenn `acme_*` in `lab.local.yaml` gesetzt ist.

## Folgen

Ein gestohlener CA-Schlüssel kann weiter Namen unter der Lab-Domain fälschen. Die Rotation ist ein bewusster, geführter Vorgang (`lab.sh ca-rotation`).

## Siehe auch

[Zertifikate](../certificates.md)
