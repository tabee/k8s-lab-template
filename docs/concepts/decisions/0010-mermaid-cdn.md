---
title: "ADR-0010: Diagramme: Mermaid selbst ausgeliefert, Quelltext als Rückfall"
---

# ADR-0010: Diagramme: Mermaid selbst ausgeliefert, Quelltext als Rückfall

**Status:** angenommen; die ursprüngliche Fassung (CDN akzeptiert) wurde in der Release-Vorbereitung durch Selbst-Auslieferung ersetzt

## Kontext

Zensical 0.0.72 lädt Mermaid zur Laufzeit im Browser von `unpkg.com` (schwebende Hauptversion `mermaid@11`, ohne `integrity`-Hash), sobald eine Seite einen `mermaid`-Block hat. Das Theme prüft vorher, ob es im Browser schon ein globales `mermaid` gibt, und lädt nur dann nach, wenn nicht.

## Entscheidung

Wir liefern Mermaid selbst aus, ohne das Theme zu verändern:

1. `docs/build.sh` lädt den npm-Tarball von Mermaid in der festen Version (`MERMAID_VERSION`) und prüft ihn gegen `MERMAID_TGZ_SHA512`. Stimmt der Hash nicht, bricht der Build ab.
2. `docs/vendor-mermaid.py` legt `mermaid.min.js` nach dem Bau als `assets/vendor/mermaid/mermaid-<Version>.min.js` ab und setzt vor das Theme-Skript ein eigenes `<script>` mit `integrity="sha384-…"` und `crossorigin`. Das Theme findet dann `mermaid` und kontaktiert kein CDN. Ein zweiter Lauf ändert nichts.
3. Der Build ist **fail-closed**: Ist der Download oder die Prüfung rot, gibt es keine Seite ohne Mermaid-Datei. Mit `MERMAID_SELF_HOST=0` baut man bewusst ohne (dann gilt wieder das CDN des Themes).
4. Die Doku-Site schickt eine Content-Security-Policy im Modus **Report-Only** (`gitops/workloads/docs/middleware.yaml`): `default-src 'none'`, Skripte nur von `'self'` und `'unsafe-inline'` (das Theme setzt Inline-Skripte, die je Seite verschieden sind; Hashes in der Richtlinie sind darum nicht machbar), `frame-ancestors 'none'`. `verify-docs.yml` prüft den Header, das Skript samt SRI-Hash und die Grösse der ausgelieferten Datei.

## Folgen

- Kein CDN beim Betrachten; Restrisiko R8 sinkt auf die Lieferkette beim Bauen (Tarball per Hash gepinnt).
- Die Mermaid-Datei (rund 3,5 MB) liegt auf jeder Seite mit Theme-Skript; sie wird vom Browser einmal geladen und zwischengespeichert.
- Die Richtlinie ist nur meldend. Das Umstellen auf erzwingend ist eine bewusste, getrennte Änderung (siehe [Doku-Site](../../how-to/docs-site.md#mermaid-cdn)).
- Diagramme bleiben als Text in den Seiten; ohne Skript sieht der Leser den Quelltext.

## Siehe auch

[Doku-Site](../../how-to/docs-site.md), [Sicherheitsmodell](../security-model.md), [Versionen und Pins](../../reference/versions.md)
