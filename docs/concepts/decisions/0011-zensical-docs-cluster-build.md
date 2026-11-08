---
title: "ADR-0011: Doku mit Zensical, im Cluster gebaut"
---

# ADR-0011: Doku mit Zensical, im Cluster gebaut

**Status:** angenommen

## Kontext

Die Doku soll im Lab lesbar sein und denselben Stand haben wie `main`.

## Entscheidung

Ein Pod mit Builder (Python) und Webserver (`static-web-server`) holt das Repo alle 60 Sekunden, baut mit `docs/build.sh` und tauscht `/site/next` gegen `/site/live` (`mv --exchange`). Der Bau läuft im Cluster mit `--strict`: Warnungen brechen ihn ab.

## Folgen

Wer Schreibrecht auf `main` hat, lässt Code im Builder-Pod laufen (Restrisiko R1; der Pod ist PSA `restricted`, sein Egress ist auf DNS, Git und HTTPS beschränkt).

## Siehe auch

[Doku-Site](../../how-to/docs-site.md)
