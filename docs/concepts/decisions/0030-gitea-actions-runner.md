# ADR 0030: Gitea Actions mit Job-Pods statt Docker-in-Docker

**Status:** angenommen

## Kontext

Die Workflows in `.gitea/workflows/` laufen bisher nur auf der heutigen Forge. In der Gitea im Cluster war Actions aus.
Vor dem Umzug auf den Produktionsserver soll die Gitea im Cluster die Workflows selbst ausführen
([Issue 115](https://github.com/tabee/k8s-lab-template/issues/115)). Es pushen nur der Betreiber und 2–3 Bots, aber jeder
Push führt die Workflow-Dateien **aus diesem Push** aus. Der Knoten hat 8 GiB, und das Budget hatte vorher 608 MiB Luft.
Alle Workflows nennen ein eigenes Image unter `container:`.

Geprüfte Wege:

| Weg | Ergebnis |
|---|---|
| Docker-in-Docker (`docker:dind`) | braucht `privileged: true`, ein Job kann aus dem Container auf den Knoten ausbrechen |
| Rootless DinD | braucht in Kubernetes ebenfalls `privileged` oder eine aufgeweichte seccomp-/AppArmor-/procMount-Einstellung |
| DinD in einem User-Namespace (`hostUsers: false`) | technisch möglich (seit Kubernetes 1.36 GA), aber privilegiert innerhalb des Pods, PSA müsste `privileged` erlauben, und es gibt keine Erfahrung damit im Lab |
| Host-Modus (Jobs im Runner-Container) | keine Trennung zwischen Jobs, der Job sieht die Zugangsdaten des Runners, und `container:` der Workflows ginge nicht mehr |
| **Job-Pods** (`kubernetes://` von `gitea/runner` 5.x) | jeder Job ist ein eigener Pod mit PSA `restricted`, ohne Token, mit festem Limit |

## Entscheidung

1. Gitea Actions ist an, und `DEFAULT_ACTIONS_URL` ist `self`.
2. Der Runner `gitea/runner` läuft als eigene Argo-CD-App im Namespace `gitea-runner` mit `capacity: 1`. Er startet
   jeden Job als Pod im Namespace `gitea-runner-jobs`. Es gibt keinen Docker-Daemon und keinen privilegierten Container.
3. Der Runner bekommt eine Role **nur** im Job-Namespace (die Rechte des Upstream-Beispiels). Job-Pods bekommen kein Token.
   Die NetworkPolicy lässt sie nur zu DNS, Gitea und HTTPS ins öffentliche Internet, also nicht zur API, zu S3 oder
   zu anderen Pods.
4. Eine `ResourceQuota` erzwingt einen Job-Pod mit höchstens 512 MiB. Das Budget zählt Runner (64 MiB) und diesen
   einen Job immer, zusätzlich zum grössten periodischen Job.
5. Der Runner nimmt im Backup-Fenster keinen neuen Job an: `health_check.script` meldet von 19:00 bis 02:30 UTC
   «nicht bereit» (Backups 20:00–02:30 UTC, eine Stunde Vorlauf für den längsten Job).
6. Das Registrierungs-Token ist ein globales Token (`GITEA_RUNNER_REGISTRATION_TOKEN`, Gitea 1.24+). `lab.sh init`
   erzeugt es, und SOPS legt es zweimal ab (Namespace `gitea` und `gitea-runner`). Ein Klick in der Oberfläche ist
   nicht nötig.

## Folgen

- Die Workflows laufen unverändert, solange sie keine Docker-Actions, `docker://`-Schritte oder Container-`volumes`
  nutzen. Ein Job läuft als uid 1000 statt als root.
- HTTPS ins ganze Internet bleibt offen (PyPI, GitHub-Releases, trivy-Datenbank). Ein bösartiger Push kann Repo-Daten
  hinaustragen, die er ohnehin lesen darf. Diesen Kompromiss benennt die Anleitung.
- Das Budget hat in Prod nur noch 32 MiB Luft (6624 von 6656 MiB), weil es den CI-Job trotz Sperre voll zählt.
  Eine weitere Site oder ein grösserer Job braucht vorher Platz, zum Beispiel durch gemessene Limits oder eine
  Kalenderprüfung, die die Sperre des Runners kennt (dann 6112 MiB).
- Ein Push zwischen 19:00 und 02:30 UTC wartet bis 02:30 UTC auf seinen Lauf.
- Image-Builds und Runner für fremde Apps bleiben bei [Issue 87](https://github.com/tabee/k8s-lab-template/issues/87).

## Siehe auch

- [Gitea Actions im Cluster](../../how-to/gitea-actions.md)
- [Memory-Budget](../../reference/memory-budget.md#gitea-actions)
- Upstream: Gitea Runner, «Install on Kubernetes» (Job pods)
