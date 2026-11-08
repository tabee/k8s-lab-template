---
title: "ADR-0024: GitHub als schaltbare Quelle von Argo CD"
---

# ADR-0024: GitHub als schaltbare Quelle von Argo CD

**Status:** angenommen (Wunsch des Betreibers: den Neuaufbau einmal vollständig aus dem GitHub-Spiegel durchspielen)

## Kontext

Der Neuaufbau soll ohne den eigenen Git-Server gelingen. Dafür gibt es den privaten GitHub-Spiegel
([ADR-0023](0023-signed-main-and-source-trust.md), [Anleitung](../../how-to/github-push-mirror.md)). Bisher hiess das:
`repo_url`, Host-Keys und Egress von Hand umstellen. Das ist fehleranfällig und wird selten geübt. Argo CD liest nur
Git: Die Quelle steht deshalb auch in Dateien unter `gitops/` und muss signiert auf `main` liegen.

## Entscheidung

1. **Ein Schalter `source: gitea | github`** in `lab.yaml` (Standard `gitea`), überschreibbar in `lab.local.yaml`. Im
   Modus `github` gilt `github_repo_url` (`ssh://git@github.com/OWNER/REPO.git`, nur `github.com`, Port 22) anstelle
   von `repo_url`. `lab.sh source status | github | gitea` setzt den Schalter und ruft `customize` und `repo-egress`
   auf; commit, Signatur und Merge bleiben Handarbeit.
2. **Feste Host-Keys:** `github_known_hosts` trägt die drei Schlüssel von `github.com`. Tests vergleichen ihre
   Fingerabdrücke mit GitHubs veröffentlichter Liste; `customize --fetch-host-keys` bricht bei einem Schlüssel ab, der
   nicht zur Liste gehört.
3. **Egress:** im GitHub-Modus erlaubt die NetworkPolicy die Bereiche aus `github_egress_cidrs` (kleinste erlaubte
   Präfixlänge /20, bei Gitea /24) und nur Port 22. Der Preflight prüft, dass `github.com` jetzt in diesen Bereichen
   liegt (`DRIFT` sonst).
4. **Quellvertrauen immer an,** `source_trust: off` wird abgelehnt. Zusätzlich zu ADR-0023 muss der Commit auf GitHub
   **derselbe sein wie `origin/main` des Git-Servers**: der Spiegel hat dann weder Vorsprung noch Rückstand. Hinter
   Gitea (`BEHIND`): der Mirror hat noch nicht synchronisiert. Woanders: der Spiegel wurde verändert. Beides bricht ab.
   Der Anker (`trusted-head`) rückt nur auf einen Commit vor, den auch der Git-Server hat; ein abweichender Spiegel wird
   geprüft, aber nie aufgezeichnet. `PIN_REV` (Argo CD an den geprüften Commit binden) gilt wie bisher.
   **Gitea nicht erreichbar:** Der Spiegel ist gerade für diesen Fall gedacht, darum bricht ein fehlgeschlagener Abruf
   von `origin` im GitHub-Modus nicht ab. `lab.sh` warnt und vergleicht GitHub mit dem letzten lokal bekannten Stand
   (lokaler `main`, `origin/main` wie zuletzt geholt; Branch `main` und saubere verfolgte Dateien werden verlangt).
   Gleich: in Ordnung. Vorfahre: `BEHIND`, Fehler. Nicht gleich und kein Vorfahre (GitHub kennt Commits, die dieser Rechner
   nie von Gitea sah): Fehler, weiter nur nach `git log HEAD..r` mit `--trust-override` und getippter Bestätigung; der Anker
   wird nie auf einen lokal ungesehenen Commit gesetzt. Gitea-Modus unverändert: ein fehlgeschlagener Abruf ist ein Fehler.
5. **Secrets:** im GitHub-Modus kommt der Ciphertext aus demselben Repo wie der Code. `secrets_repo_url` muss leer
   sein, sonst bricht `lab.sh` ab. Ein Deploy-Key gilt nur für ein GitHub-Repo; ein zweites Secrets-Repo bräuchte
   einen zweiten Schlüssel und ein zweites Repo und ist nicht gebaut.
6. **Die öffentliche Fassung** ersetzt den GitHub-Kontonamen wie alle persönlichen Werte.

## Verworfene Alternativen

| Option | Warum nicht |
|---|---|
| Nur Doku, `repo_url` von Hand umstellen | Der Test wird nie geübt, und ein Tippfehler fällt erst im Neuaufbau auf. |
| Argo CD liest beide Quellen | Zwei Wahrheiten; ein Rollback der Kopie bliebe unbemerkt. |
| GitHub-Host-Keys per `ssh-keyscan` ohne Vergleich | Blindvertrauen beim ersten Abruf; die Liste von GitHub ist der unabhängige Beleg. |
| Egress mit `github.com` als DNS-Name | Die NetworkPolicies im Lab sind der Kubernetes-Standardtyp und kennen nur Adressbereiche, keine Namen. |
| SSH über `ssh.github.com:443` | Bewusst verworfen (2026-11-08). Anderer Host, anderer Port, eigene Host-Keys und Bereiche. Dass Port 443 im Lab ohnehin offen ist, hilft nicht: die Egress-Regel der Pods ist pro Ziel und Port geschrieben, ein zweiter Weg würde sie nur breiter machen. `lab.sh` lässt für `source: github` darum nur `ssh://git@github.com/…` auf Port 22 zu und bricht sonst ab. Eng bleibt der Egress über die Git-Bereiche aus `api.github.com/meta` (Feld `git`) und die DNS-Drift-Prüfung im Preflight. Erst wieder ein Thema, wenn ein Netz Port 22 sperrt. |

## Folgen

- Der Wechsel in beide Richtungen ist eine signierte Änderung an `main`. Ablauf und Prüfpunkte:
  [Neuaufbau aus GitHub](../../how-to/neuaufbau-github.md).
- Die Bereiche von GitHub wechseln ([Issue 72](https://github.com/tabee/k8s-lab-template/issues/72)): der Preflight
  meldet es, die Pflege bleibt Handarbeit.
- Die Host-Keys von `github.com` sind fest eingetragen (`github_known_hosts`) und werden gegen GitHubs offizielle
  Fingerabdruck-Liste geprüft: offline von `tests/trust-tests.sh`, beim Neuholen von `customize --fetch-host-keys`
  (bricht bei Abweichung ab). Abgeglichen mit `api.github.com/meta` (`ssh_key_fingerprints`) am 2026-11-08.
- Der Spiegel muss synchron sein. Nach einem Push auf `main` ist der Neuaufbau erst möglich, wenn der Mirror
  nachgezogen hat.
- Ohne erreichbares Gitea ist der lokale Klon die Referenz und muss aktuell sein. Der Rest, den kein Klon abdeckt (Gitea
  kennt einen neueren Stand), bleibt offen; Signaturen und Anker begrenzen ihn.
- Web-Merges liefern unsignierte Commits und scheitern an Punkt 4 ([Issue 73](https://github.com/tabee/k8s-lab-template/issues/73)).
- Argo-CD-eigene Prüfung der Signaturen bleibt offen ([Issue 70](https://github.com/tabee/k8s-lab-template/issues/70)).
