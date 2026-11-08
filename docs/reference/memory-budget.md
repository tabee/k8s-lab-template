---
title: Memory-Budget
---

# Referenz: Memory-Budget

Das Lab hat einen Knoten mit `memory_mib` Arbeitsspeicher (8192 MiB, gleich viel wie der geplante Produktionsserver, siehe [Gleicher Arbeitsspeicher wie Prod](#prod-paritaet)). Alles, was darauf läuft, bekommt ein
Memory-Limit. Dieses Budget sorgt dafür, dass die **Summe der Limits** plus eine Reserve in den Knoten passt. Es ist
[Issue 9](https://github.com/tabee/k8s-lab-template/issues/9); das Sicherheitsrisiko dahinter ist
[R12](../concepts/security-model.md).

## Die Regel

```text
Summe der Memory-Limits aller Arbeits-Pods  +  memory_reserve_mib   <=   memory_mib
```

- **Arbeits-Pods** sind alle Pods in `Running` oder `Pending` in jedem Namespace ausser `kube-system`. Init-Container
  zählen nicht (sie laufen vor den anderen), ausser dem Barman-Sidecar der CNPG-Pods: er ist ein Init-Container mit
  `restartPolicy: Always`, läuft so lange wie der Pod und zählt mit. Für jeden Pod zählt die Summe der Limits seiner Container.
- **Reserve** (`memory_reserve_mib`, Standard 1536 MiB): `kube-system` (k3s, CoreDNS, metrics-server), Betriebssystem,
  kubelet und ein Backup- oder Restore-Pod, der gerade läuft. Der Wert steht in `lab.yaml`.
- **Kein Limit, kein Budget.** Ein Container ohne Limit macht die Prüfung rot (`NOLIMIT`), ebenso ein unlesbarer Wert
  (`BADLIMIT`).
- **Speicherdruck** auf dem Knoten (`MemoryPressure`) macht sie ebenfalls rot (`PRESSURE`).

`ansible/verify-budget.yml` liest die Pods und den Knoten aus dem Cluster und ruft `scripts/memory-budget.py check` auf
(die einzige Stelle der Rechnung). Es ist Phase 15 der Abnahme ([Abnahme-Prüfungen](acceptance-checks.md#phase-15)) und
läuft auch einzeln: `cd ansible && ansible-playbook verify-budget.yml`.

## `LimitRange` als Netz unter dem Budget

In jedem Arbeits-Namespace (`whoami`, `docs`, `db-lab`, `gitea`, `matrix`, `keycloak` und jeder `notes-*`) legt Git eine `LimitRange`
`lab-memory` an. Sie wirkt nur auf Pods **ohne** eigene Angabe und nur auf Memory:

| Feld | Wert | Wirkung |
|---|---|---|
| `default` | 256 MiB | Limit für einen Container ohne Limit |
| `defaultRequest` | 64 MiB | Request für einen Container ohne Request |
| `max` | 1 GiB | kein Container darf mehr als das verlangen |

!!! warning "Die Voreinstellung ist kein Ersatz für eine Messung"
    Ein neuer Container ohne eigenes Limit bekommt 256 MiB. Das hält das Budget ein, kann aber für eine echte Last zu
    wenig sein: der Container wird dann vom Kernel beendet (OOM-Kill) und von Kubernetes neu gestartet. Wer eine neue
    App hinzufügt, setzt das Limit selbst und trägt die Markierung ein (siehe unten).

## Workflow: messen, ansehen, übernehmen

1. **Messen.** `bash scripts/lab.sh acceptance` startet im Hintergrund einen Sampler: er liest alle 10 Sekunden
   `kubectl top` und merkt sich die Spitze jedes Containers (`<log_dir>/memory-peaks.json`, höchstens zwei Stunden).
   Die Abnahme enthält die Backup- und Restore-Läufe von Gitea und Postgres; das sind die Spitzen, die zählen.
2. **Ansehen.** `bash scripts/lab.sh budget` vergleicht die Spitzen mit den Limits in Git und druckt einen Vorschlag.
   Es ändert nichts.
3. **Übernehmen.** `bash scripts/lab.sh budget --apply` schreibt die vorgeschlagenen Limits in die Dateien, hebt
   bei Bedarf `memory_reserve_mib` an und erneuert die Tabelle unten. **Vorschlag prüfen, nicht blind übernehmen:**
   Die manuellen Untergrenzen und die Einschränkungen der Reserve-Messung unten gelten weiterhin. Dann `git diff`
   ansehen, committen, pushen, `cd ansible && ansible-playbook argocd.yml` (die Limits von Argo CD selbst) und die Abnahme wiederholen. Die zweite
   Abnahme muss grün sein und darf keinen Speicherdruck zeigen.

### Die Regel der Übernahme

```text
neu = min(aktuell, max(64 MiB, aufgerundet auf 32 MiB (Spitze * 1,5)))
```

- Ein Limit wird **nie erhöht**. Nur die Reserve darf steigen.
- Liegt die Spitze über 70 % des heutigen Limits, bleibt das Limit (kein Grund zum Senken).
- Liegt das Limit unter Spitze * 1,2, steht es als `FLAG` im Bericht: die Anhebung ist eine Entscheidung von dir, kein
  Automatismus.
- Container ohne Messwert (`NOPEAK`) bleiben unverändert.

### Die Markierung `# lab-limit:`

Jede Zeile mit einem Limit, die das Werkzeug ändern darf, trägt einen Kommentar:

```yaml
memory: 256Mi   # lab-limit: gitea/gitea-db/postgres
```

Der Teil nach dem Doppelpunkt ist `Namespace/Workload/Container`; jeder Teil darf ein Muster mit `*` sein, und mehrere
Muster stehen durch Leerzeichen getrennt. Der Workload ist der Pod-Name ohne ReplicaSet-Hash und ohne `-N`-Endung.
Eine Zeile ohne Markierung fasst das Werkzeug nicht an.

!!! warning "Aus Messwerten abgeleitete Limits können bei ungemessener Last OOM-Kills auslösen"
    Die Spitze stammt aus **einer** Abnahme. Eine seltene oder grössere Last (viele Pushes in Gitea, ein langer
    Restore, ein Argo-CD-Sync mit vielen Apps) kann darüber liegen. Der Faktor 1,5 ist eine Reserve, keine Garantie.
    Ein OOM-Kill zeigt sich als Neustart des Pods (`kubectl get pods`, Spalte `RESTARTS`; `kubectl describe pod`,
    `OOMKilled`). Dann hebst du das Limit von Hand an und passt bei Bedarf die Reserve an; das Budget meldet, wenn es
    nicht mehr aufgeht.

## Historische Ausgangslage

Vor der Übernahme der Messwerte waren die Limits deutlich grösser als das 8-GiB-Budget.
Die Tabelle unter «Budget nach der Messung» rechnet den Stand `1dd0b72` und die neuen Werte mit denselben
Instanzzahlen nach. Alte Schätzungen und einfache Summen der Markierungszeilen sind keine Pod-Budgets:
Eine Markierung kann mehrere Instanzen meinen; eine Job-Vorlage läuft nicht ständig.
Im Lab bleibt `memory_budget_enforce: false`, in Prod bleibt es `true`. `NOLIMIT`, `BADLIMIT` und Speicherdruck
sind in beiden Profilen Fehler. Die Anzahl der Instanzen wird mit dieser Änderung nicht gesenkt.

## Messung mit Keycloak (Probelauf auf der Box)

Der Probelauf (k3s in Docker mit den echten Manifesten, vier CNPG-Cluster, Gitea, Synapse, Element, Keycloak, K8up,
cert-manager, Traefik; ohne Argo CD) wurde von Aufbau bis Wiederherstellung dreimal gespielt und alle 5 bis 7 Sekunden
gemessen (Arbeitsspeicher des Knotens ohne Seitencache, `docker stats` des Knoten-Containers):

| Zeitpunkt | Wert |
|---|---|
| Ruhezustand nach dem Aufbau, Summe der Pod-Arbeitssätze | rund 2,0 GiB |
| davon Keycloak (Server) / `keycloak-db` | 588 MiB / 93 MiB |
| Ruhezustand, ganzer Knoten (Pods, k3s, containerd, Kernel) | 4,1 GiB |
| **Spitze** (Aufbau, erste Backups aller vier Cluster, K8up-Läufe) | **4,35 bis 4,45 GiB** |
| Wiederherstellung (vier Recovery-Cluster, K8up-Restore) | höchstens 4,0 GiB |
| Summe der Limits (mit Argo CD, `whoami` und Docs-Pod) | 16 704 MiB (Budget bei 8192: 6656 MiB) |

Dazu kommen im echten Lab, was die Box nicht hatte: **Argo CD** (rund 0,8 bis 1,1 GiB im Betrieb), das
Betriebssystem der VM und der Seitencache (rund 0,4 GiB). Das ergibt eine Spitze von rund **5,9 GiB**.

Die frühere Empfehlung, die Lab-VM mit `memory_mib: 10240` in `lab.local.yaml` grösser zu machen, gilt nicht mehr
(siehe nächster Abschnitt).

## Gleicher Arbeitsspeicher wie Prod {#prod-paritaet}

Die Lab-VM hat genau so viel Arbeitsspeicher wie der geplante Produktionsserver: `memory_mib` in
`infra/envs/local/lab.yaml` ist gleich `memory_mib` in `infra/envs/prod/lab.yaml` (8192 MiB, Server-Typ `cpx32`).
So ist jeder Neuaufbau und jede Abnahme im Lab ein ehrlicher 8-GB-Test für Prod
([Issue 9](https://github.com/tabee/k8s-lab-template/issues/9)).

- `tests/prod-tests.sh` prüft, dass beide Werte gleich sind.
- Der Preflight von `lab.sh` warnt, wenn `lab.local.yaml` den Wert überschreibt
  (`VM memory … differs from the prod profile`). Die Warnung bricht nichts ab: Auf einem kleineren PC darfst du
  weniger geben, das Lab ist dann aber kein Prod-Test mehr.
- Wer bisher `memory_mib: 10240` in `infra/envs/local/lab.local.yaml` hatte: Zeile löschen. Wirksam wird der Wert
  erst beim nächsten `bash scripts/lab.sh rebuild --restore` (Tofu baut die VM neu).

### Messung vom 07.11.2026 (Lab-VM mit rund 10 GiB, `kubectl top`)

| Zeitpunkt | Belegt auf dem Knoten |
|---|---|
| Ruhezustand | rund 5,5 GiB |
| Spitze während `rebuild --restore` | 4970 MiB |
| Spitze direkt danach (erste CNPG- und K8up-Backups) | 5127 MiB |

Diese erste Messung war noch keine Freigabe für 8 GiB: Sie lief auf der grösseren VM und übersieht kurze Spitzen.
Der anschliessende Wiederherstellungslauf auf 8192 MiB ist unten dokumentiert.

### Budget nach der Messung vom 07.11.2026

Die 37 Markierungszeilen sinken von **14 528 auf 6688 MiB**. Das ist ausdrücklich **nicht** die Summe der laufenden Pods.
Gezählt werden die fünf Argo-CD-Container aus dem Ansible-Template, die Plattform-Controller, Docs, alle Sites aus
`gitops/sites.yaml`, alle CNPG-Instanzen samt dauerhaftem Barman-Sidecar und alle Pooler-Replikate.
Der gebündelte Stand enthält **eine** Site (`notes-notes`, SSO), Gitea und Matrix mit je **zwei** DB-Instanzen,
Keycloak mit **einer** DB-Instanz sowie im Lab drei `pg-lab`-Instanzen, zwei Lab-Pooler und zwei `whoami`-Pods.
Weitere Sites kosten je 320 MiB (Builder und Web), mit SSO zusätzlich 64 MiB. Keine Site wird als blosses Muster
`notes-*` einmal pauschal abgerechnet.

| Profil / gleichzeitig aktive Last | Neu MiB | Budget MiB | Rest / Fehlbetrag MiB |
|---|---:|---:|---:|
| Prod, Dauerbetrieb ohne beendete Jobs | 5600 | 6656 | +1056 |
| **Prod, Dauerbetrieb plus grösster einzelner Job plus ein CI-Job** | **6624** | **6656** | **+32** |
| Prod, nur Realm-Konfiguration und CI-Job zusätzlich | 6496 | 6656 | +160 |
| Lab, Dauerbetrieb | 6880 | 6656 | **−224** |
| Lab, Dauerbetrieb plus grösster einzelner Job plus ein CI-Job | 7904 | 6656 | **−1248** |
| Ohne Staffelung: Prod, beide K8up-Pods, Realm-Konfiguration und CI-Job | 7520 | 6656 | **−864** |

Stand mit [Gitea Actions](#gitea-actions) (08.11.2026): Runner 64 MiB im Dauerbetrieb, ein CI-Job mit 512 MiB
in jedem Profil ausser `--steady`. Vorher waren es 5536 und 6048 MiB (+608).

```bash
python3 scripts/prod-budget-check.py --repo . --steady
python3 scripts/prod-budget-check.py --repo .
python3 scripts/prod-budget-check.py --repo . --profile lab
```

Der Standardaufruf prüft nun zuerst den begrenzten Kalender mit `memory-budget.py` und modelliert dann
**Dauerbetrieb + Maximum eines einzelnen Jobs**: max(512 MiB K8up, 384 MiB Realm-Konfiguration) = 512 MiB.
Bei ungültigem Kalender bleibt die konservative Summe; das erzwingende Prod-Profil bricht ab.
`--steady` zeigt nur den Dauerbetrieb, ist aber kein Umgehen der Kalenderprüfung.
Der Redis-Secret-Init-Hook (64 MiB, vor den Controllern) ist nicht gleichzeitig enthalten.
Prüf-, Recovery- und andere Init-Hook-Pods sowie überlappende Rollouts kommen je nach Zeitpunkt hinzu.

**Der Live-Check rechnet niemals mit diesem Maximum statt der echten Pods.** Er summiert weiterhin alle
`Running`- und `Pending`-Pods samt nativen Sidecars. Im erzwingenden Prod-Profil liest `verify-budget.yml`
zusätzlich die tatsächlich ausgerollten K8up-Schedules, PodConfigs und das Argo-CD-AppProject. Ein fehlender
Wächter, überlappende Zeitfenster oder mehr als ein aktiver K8up-/Realm-Pod ergeben `STAGGER` und einen Fehler,
auch wenn deren Speicher gerade noch ins Budget passt. Im Lab bleibt die Prüfung nicht erzwingend:
Gleichzeitige Jobs warnen, die echten Limits werden trotzdem vollständig addiert.

### Staffelung ab 08.11.2026

Alle Cron-Ausdrücke bleiben deterministisch in **UTC**, ohne Zufalls- oder Intervallplan. Die Reihenfolge
schliesst Prune und Check ein: Auch diese K8up-Pods haben je 512 MiB. Die Sonntagschecks laufen früh am Sonntag
und prüfen somit unter anderem die Sicherungen vom Samstagabend.

| Aktion | Bisher UTC | Neu UTC | Neu Europe/Zurich (Winter / Sommer) |
|---|---|---|---|
| Gitea Backup, täglich | 20:30 | 20:30 | 21:30 / 22:30 |
| Matrix Backup, täglich | 20:45 | 21:30 | 22:30 / 23:30 |
| Gitea Prune, täglich | 21:00 | 22:30 | 23:30 / 00:30 am Folgetag |
| Matrix Prune, täglich | 21:15 | 23:30 | 00:30 / 01:30 am Folgetag |
| Gitea Check, Sonntag | So 21:30 | So 00:30 | So 01:30 / 02:30 |
| Matrix Check, Sonntag | So 21:45 | So 01:30 | So 02:30 / 03:30 |

Jede Aktion setzt `concurrentRunsAllowed: false` und `activeDeadlineSeconds: 1800`. Der Pod hat explizit
30 Sekunden Beendigungsfrist. Die Kalenderprüfung reserviert pro Start **30 Minuten Laufzeit + 5 Minuten**
für Beendigung und Controller-Verzögerung; bis zum nächsten Stundenplatz bleiben 25 Minuten Luft. Die
Wochenprüfung berücksichtigt den Übergang Samstag/Sonntag und Tagesgrenzen.

Der Abschlussbericht des 8-GiB-Restores meldete für **alle ersten CNPG- und K8up-Backups zusammen 1 min 12 s**.
Das ist kein gemessenes Maximum einer einzelnen periodischen Prune-/Check-Aktion; solche Laufzeitmessungen
liegen in den hier verfügbaren Top-12-Daten nicht vor. 30 Minuten sind deshalb eine bewusst gesetzte Grenze,
nicht ein behaupteter Messwert. Langsame Läufe werden danach fehlgeschlagen beendet und müssen untersucht
werden. Der Kubernetes-Controller leitet die Beendigung ein; bei einem hängenden Knoten ist eine pünktliche
Beendigung nicht garantiert. Die erste Nacht mit echten Backup-, Prune- und Check-Laufzeiten ist noch abzunehmen.

CNPG-ScheduledBackups bleiben unverändert (Lab/Gitea 20:00 UTC, Matrix 20:15 UTC, Keycloak 20:20 UTC).
`method: plugin` führt die Arbeit in den bereits pro DB-Instanz budgetierten Barman-Sidecars aus; es kommt
kein weiterer 512-MiB-Jobplatz hinzu. Die Kalenderprüfung weist einen Methodenwechsel zurück.
Giteas interne Wartungsaufgaben laufen ebenfalls im bereits budgetierten Hauptcontainer.
Die Semantik der verwendeten Felder steht in der [K8up-2.16-API-Referenz](https://docs.k8up.io/k8up/2.16/references/api-reference.html).
`lab-backup-fresh.py` wartet bereits jeden manuellen Datei-Backup-Lauf einzeln ab; es sperrt jedoch keine
parallel anlaufenden Cron-Aktionen oder Argo-Syncs.

### Keycloak und manuelle Läufe: verbindliche Betriebsregel

Das AppProject aus `ansible/roles/argocd_bootstrap/tasks/gitops.yml` verweigert neue Syncs der App `keycloak`
täglich **20:00–02:30 UTC** (Europe/Zurich: **21:00–03:30 im Winter, 22:00–04:30 im Sommer**).
`manualSync: false` schliesst normale manuelle Syncs ein. `syncOverrun: false` erlaubt auch einem vorher
begonnenen automatischen Sync kein Weiterlaufen über die Sperrgrenze (Argo CD 3.5). Bereits erstellte
Hook-Pods werden damit nicht rückwirkend entfernt. Der PostSync-Job behält seine 900-Sekunden-Grenze und 384 MiB. Die Sperre beginnt vor dem ersten Backup und umfasst alle sechs Slots;
für einen vor Beginn gestarteten Hook ist eine zusätzliche Vorlaufreserve eingeplant.

!!! warning "Kein verteilter gegenseitiger Ausschluss"
    `concurrentRunsAllowed` gilt je K8up-Aktion, nicht zwischen Namespaces oder Aktionstypen.
    Argo blockiert mit `syncOverrun: false` die Fortsetzung automatischer Syncs, ist aber keine Kubernetes-
    Zulassungssperre: Bereits erstellte Pods laufen bis zu ihrer Deadline weiter. Der Übergang eines laufenden
    Syncs in die Sperre muss mit der gepinnten Version noch live geprüft werden. Ein stark verspäteter Controller
    kann zudem die angenommene Verzögerung von fünf Minuten überschreiten. Deshalb ist die Freigabe des 6048-MiB-Modells (mit Gitea Actions 6624 MiB) **an die Betriebsregel gebunden**,
    keine technisch garantierte Ausschluss-Sperre. Der Live-Check erkennt einen Verstoss, verhindert ihn aber nicht.

Die Feldsemantik beschreibt [Argo CD 3.5: Sync-Fenster](https://argo-cd.readthedocs.io/en/release-3.5/user-guide/sync_windows/).

1. Vor der nächtlichen Sperre muss ein laufender Keycloak-Sync samt PostSync-Hook abgeschlossen sein; keinen
   langen Sync in das Backup-Fenster hineinlaufen lassen. Normale Realm-Änderungen ausserhalb der Sperre ausrollen.
2. Manuelle Backups, Restore-/Prüfjobs und ein erneuter Realm-Sync laufen **einzeln**, nicht parallel zu einem
   nächtlichen Slot. Das gilt auch für Neuaufbau, Abnahme und «erste Backups». Bei Wartung zuerst die
   K8up-Aktionen vorübergehend kontrolliert über Git deaktivieren und bereits laufende Jobs vollständig abwarten.
   Argo-SelfHeal darf sie dabei nicht zurücksetzen. Diese Änderung liefert keinen Wartungs-Automatismus;
   K8up 2.16 hat keinen dokumentierten `Schedule.spec.suspend`-Schalter.
3. Bei Notfall-Recovery während der Sperre erst diese Ruhe herstellen; dann den Sync-Wächter bewusst und
   nachvollziehbar für die Wartung behandeln, danach Zeitpläne und Wächter wiederherstellen. Kein automatischer
   Bypass ist eingebaut. Ohne diese Schritte kann die Sperre den Wiederaufbau bis 02:30 UTC verzögern.
4. Nach dem Ausrollen: `ansible/argocd.yml` für den AppProject-Wächter, GitOps-Sync für Schedules/PodConfigs,
   dann `verify-budget.yml` im Prod-Profil und die Abnahme. Die aus Git projizierten Knotenbedingungen sind
   keine Live-Messung. Eine neue Site oder ein weiterer Job benötigt eine neue Budgetprüfung.

Das Lab bleibt mit Übungslasten 672 MiB über dem Budget im gestaffelten Spitzenfall; Instanzzahlen,
Limits und `memory_reserve_mib: 1536` werden mit dieser Staffelung nicht geändert.

### Bewusste Untergrenzen statt blindem `--apply`

- Notes-Builder: **256 MiB**, Docs-Builder: **192 MiB**. Zwischen den Builds schlafen sie; 2 MiB im alten
  Notes-Sample sind kein Zensical-/Python-/Git-Build-Peak. Der Restore zeigte 61 beziehungsweise 102 MiB.
- Gitea: **256 MiB** für Go und Git-Spitzen; Gitea-Postgres **256 MiB** (Restore-Spitze 133 MiB).
  Die anderen Postgres-Container bekommen mindestens **192 MiB**.
- Keycloak bleibt bei **896 MiB** (617 MiB gemessen), Argo-CD-Application-Controller bei **512 MiB**
  (387 MiB beim Restore). Das ist weniger als Faktor 1,5 für den Controller, aber die vorgegebene Untergrenze;
  grossen Sync erneut beobachten. Argo-CD-Server: **96 MiB**, nicht 64 MiB (54 MiB gemessen).
- Barman läuft als dauerhafter Sidecar und zählt pro DB-Instanz. Limits: Lab 128, Gitea 192, Matrix 160,
  Keycloak 160 MiB; Plugin-Controller 128 MiB. Die Recovery-Sidecars erreichten bis zu 107 MiB in Gitea,
  106 MiB in Matrix und 100 MiB in Keycloak. Barman bekommt **nie 64 MiB** (OOM-Vorgeschichte).
- Unzureichend gemessene, nur zeitweise laufende Backup-/Restore-, Config- und Verify-Container behalten ihre
  bestehenden Limits: K8up 512 MiB pro Pod, Realm-Konfiguration 384 MiB, `pg-lab-verify` 512 MiB
  (nur eine Beobachtung), weitere Prüfer 64/128 MiB und bestehende normale Init-Container unverändert.
  CNPGs generierte `full-recovery`-Container erben dagegen die Ressourcen des jeweiligen Clusters;
  die Senkung der Cluster-Limits wirkt auch dort. Ihre gemessenen Spitzen lagen bei 63–77 MiB,
  ihre Barman-Sidecars sind in den oben genannten Recovery-Spitzen berücksichtigt.
- Damit Requests keine ungültigen Pods erzeugen, sinken **nur** Requests oberhalb des neuen Limits:
  Synapse und Matrix-/Lab-Postgres auf 128 MiB, CNPG-/K8up-Operator und Argo-CD-Server auf 64 MiB.
  CPU-Werte bleiben unverändert.

### Warum die Reserve bei 1536 MiB bleibt

Der Bericht schlägt 3648 MiB vor: `ceil64(47 + 3083) + 512`. `sample_once()` berechnet 3083 MiB aber als
Maximum von **Node-Nutzung minus Summe der Container-Nutzung**. Die Aufrufe erfolgen nacheinander; Node- und
Pod-Arbeitssätze sind nicht exakt zeitgleich und haben unterschiedliche Messgrenzen. Die Differenz kann neben
Host-Prozessen, k3s und kubelet auch aktiven Seitencache sowie während des Abfragens fehlende Container enthalten.
`needed_reserve()` addiert ausserdem separat maximierte Werte und pauschal einen Jobplatz. Der Live-Check zählt
aktive Jobs bereits in der Limit-Summe. Die Rechnung ist ein konservativer Hinweis, kein Nachweis von genau
3130 MiB nicht freigebbarem OS-/kubelet-Bedarf.

Die vorhandene JSON-Datei enthält 401 vollständige Abnahme-Stichproben vom 06.11.; trotz ihres Dateinamens
fehlen darin höhere Container-Peaks des 07.11. Die zusätzliche Top-12-Aufzeichnung liefert keine vollständige
Pod-Summe und darf nicht zur Berechnung des Overheads dienen. Deshalb bleibt `memory_reserve_mib: 1536`
unverändert nach der vereinbarten Regel (8192 − 1536 = 6656 MiB). **Dass 1536 MiB den tatsächlichen
nicht freigebbaren Overhead sicher abdecken, ist damit nicht bewiesen.** Dafür braucht es zeitgleiche vollständige
Node-/Pod- und Host-/Cache-Messungen unter Last; die gemessene Belegung allein ersetzt sie nicht.

## Gitea Actions {#gitea-actions}

Der Runner und seine Job-Pods ([Gitea Actions im Cluster](../how-to/gitea-actions.md),
[ADR 0030](../concepts/decisions/0030-gitea-actions-runner.md)):

| Teil | Request | Limit | Markierung |
|---|---:|---:|---|
| Runner (`gitea/runner`, `GOMEMLIMIT=48MiB`) | 32 MiB | 64 MiB | `# lab-limit: gitea-runner/gitea-runner/runner` |
| ein Job-Pod (Image aus `container:` des Workflows) | 512 MiB | 512 MiB | `# lab-limit: gitea-runner-jobs/*/job` |

- Der Runner hat `capacity: 1`. Die `ResourceQuota` im Namespace `gitea-runner-jobs` erlaubt **einen** Pod mit
  höchstens 512 MiB (Request = Limit, damit der Scheduler den Platz wirklich freihält). Mehr als ein Job ist so auch
  bei einem Fehler im Runner nicht möglich.
- Ein CI-Job ist kein Teil des Backup-Kalenders. Ein Push kann jederzeit kommen, auch während K8up läuft. Darum zählt
  `scripts/prod-budget-check.py` den Job-Pod **immer voll** dazu, zusätzlich zum grössten periodischen Job. Nur
  `--steady` lässt ihn weg.
- Beide Werte sind noch **nicht gemessen**. `lint` installiert ansible-lint und yamllint, `security` lädt die
  trivy-Datenbank. Nach den ersten echten Läufen `kubectl top pod -n gitea-runner-jobs` ansehen und die Regel der
  Übernahme anwenden.
- Der Runner nimmt von 19:00 bis 02:30 UTC keinen neuen Job an (`health_check.script`, siehe
  [Gitea Actions](../how-to/gitea-actions.md#backup-fenster)). Im Betrieb laufen CI-Job und K8up also nicht
  gleichzeitig. Das Budget rechnet trotzdem beide, weil die Sperre eine Einstellung des Runners ist und keine
  Grenze von Kubernetes.
- Mit 32 MiB Luft in Prod passt nichts mehr dazu. Weitere Sites oder ein grösseres Job-Limit brauchen vorher Platz.
  Dürfte das Modell CI und K8up als sich ausschliessend rechnen, wären es 6112 MiB (544 MiB Luft). Das bräuchte eine
  Kalenderprüfung, die auch die Sperre des Runners liest, und ist bewusst noch nicht umgesetzt.

## Login-Proxy der Notiz-Sites (oauth2-proxy)

Jede Notiz-Site mit `auth: sso` bekommt einen Pod `notes-oauth2-proxy` ([ADR 0021](../concepts/decisions/0021-notes-sso.md)).
Er ist klein und ohne Zustand (kein Volume, keine Datenbank, Sitzung im Cookie):

| Wert | Grösse |
|---|---|
| Request | 24 MiB Arbeitsspeicher, 10m CPU |
| Limit | 64 MiB Arbeitsspeicher, keine CPU-Grenze |
| Gemessen (Probelauf auf der Box, Anmeldung und Abmeldung) | rund 6 MiB im Ruhezustand |
| Zusatz pro SSO-Site in der Summe der Limits | 64 MiB |

Heute gibt es eine SSO-Site (`notes`): 64 MiB mehr in der Summe der Limits, also keine spürbare Änderung des
Befunds oben. Die Markierung `# lab-limit: notes-*/notes-oauth2-proxy/oauth2-proxy` steht in
`gitops/charts/notes-site/templates/oauth2-proxy.yaml`; `scripts/memory-budget.py` zählt den Pod pro Namespace
`notes-*` mit. Der Proxy braucht kein Backup und keine Wiederherstellung (er ist ohne Zustand); er läuft auf dem
8-GiB-Knoten der Produktion genauso wie hier. Wer viele SSO-Sites anlegt, rechnet 64 MiB pro Site dazu (`lab.sh budget`).

## Gemessene Werte

### Wiederherstellung auf 8 GiB (07.11.2026)

`rebuild --restore` auf `1dd0b72`: **22 min 12 s**, Ende **23:29:06 Europe/Zurich**, Exit 0,
alle Ablaufphasen OK. Gitea- und Matrix-Anmeldung mit dem bestehenden Benutzer anschliessend bestätigt.
Die Import-Abnahme ohne gespeicherte Baselines ist weiterhin kein Beleg für importierte Produktionsdaten.

| Messpunkt | Wert |
|---|---|
| Node-Spitze, erste Backups nach dem Restore, 23:28:00 Europe/Zurich | **5332 MiB, 67 %** laut `kubectl top` |
| Dauerbetrieb nach dem Restore | rund **4700 MiB, 59 %** laut `kubectl top` |
| Gemeldete Speicherfehler im ausgewerteten Lauf | **kein OOMKilled, keine MemoryPressure** |
| Höchster Node-Wert aus der älteren Abnahme-Datei | 5575 MiB (anderer Lauf, nicht die 8-GiB-Restore-Spitze) |

Quellen auf dem Steuerrechner: `top-restore-20261107-2308.log` und
`lab-rebuild-20261107-230655.log`. Die Node-Werte sind Stichproben im Abstand von etwa 15 Sekunden;
das Log enthält höchstens zwölf Container pro Zeitpunkt. Die Prozentwerte sind die Anzeige von `kubectl top`
und beziehen sich auf den vom Knoten gemeldeten Speicher, nicht exakt auf 8192 MiB.
Der Befund «kein OOM/Pressure» stammt aus der begleitenden Laufprüfung; das Top-Log allein beweist ihn nicht.
Keycloaks Neustarts waren DB-Verbindungsfehler beim Start, keine gemeldeten Speicherfehler.

### Nach dem Ausrollen der gesenkten Limits (08.11.2026)

| Messpunkt | Wert |
|---|---|
| Node-Spitze nach dem Rollout | **5191 MiB, 65 %** laut `kubectl top` |
| Dauerbetrieb nach dem Rollout | rund **4990 MiB** |
| Laufender Betrieb am Nachmittag, mit CI-Runner (Runner selbst rund 5 MiB) | rund **4448 MiB, 56 %** |
| Budget der Limits | 8192 − 1536 = **6656 MiB**; Prod im ungünstigsten Fall **6624 MiB** |

Der frühere Lauf auf der rund 10-GiB-VM (07.11.2026, Ende 17:12:56 Europe/Zurich, 27 min 14 s, Exit 0) hatte eine
Restore-Spitze von 4970 MiB / 49 %. Offene Messungen (Restore-Test, Replikat, Desktop-Alarm): [Issue 125](https://github.com/tabee/k8s-lab-template/issues/125).

**Die Messung vom 07.11.2026 entstand vor der Senkung der Limits.** Die Werte nach dem Rollout stehen oben (08.11.2026).

Die folgende Tabelle kombiniert die Abnahme-Peaks mit höheren Werten aus dem Restore-Log; Beobachtungen
werden pro normalisiertem Container addiert, bei Replikaten auch über Instanzen. Die neue Tabelle enthält keine
erfundenen Null-Peaks. Ohne gemessene Joblast wird kein Limit gesenkt.

<!-- memory-budget:begin -->
| Container (Namespace/Workload/Name) | Bisher MiB | Neu MiB | Spitze MiB | Beobachtungen |
|---|---:|---:|---:|---:|
| `matrix/element/element` | 256 | 64 | 4 | 404 |
| `matrix/synapse/synapse` | 768 | 192 | 120 | 426 |
| `notes-*/notes/builder` | 512 | 256 | 61 | 409 |
| `notes-*/notes/web` | 64 | 64 | 11 | 409 |
| `notes-*/notes-oauth2-proxy/oauth2-proxy` | 64 | 64 | 7 | 401 |
| `cert-manager/cert-manager/cert-manager-controller` | 256 | 64 | 30 | 410 |
| `cert-manager/cert-manager-webhook/cert-manager-webhook` | 128 | 64 | 13 | 407 |
| `cert-manager/cert-manager-cainjector/cert-manager-cainjector` | 256 | 64 | 35 | 414 |
| `cnpg-system/cloudnative-pg/manager` | 512 | 64 | 38 | 409 |
| `cnpg-system/plugin-barman-cloud/barman-cloud` | 256 | 128 | 17 | 401 |
| `k8up/k8up/k8up-operator` | 256 | 64 | 22 | 405 |
| `traefik/traefik/traefik` | 256 | 64 | 29 | 410 |
| `db-lab/pg-lab/postgres` | 512 | 192 | 109 | 1352 |
| `db-lab/pg-lab/plugin-barman-cloud` | 512 | 128 | 69 | 1330 |
| `db-lab/pg-lab-pooler-rw/pgbouncer` | 128 | 96 | 56 | 864 |
| `docs/docs/builder` | 512 | 192 | 102 | 434 |
| `docs/docs/web` | 64 | 64 | 10 | 434 |
| `gitea/gitea-db/postgres` | 512 | 256 | 133 | 845 |
| `gitea/backup-*/*` `gitea/restore-*/*` `gitea/prune-*/*` `gitea/check-*/*` | 512 | 512 | nicht gemessen | – |
| `gitea/gitea-db/plugin-barman-cloud` | 512 | 192 | 81 | 845 |
| `gitea/gitea-db-pooler-rw/pgbouncer` | 128 | 64 | 13 | 401 |
| `gitea/gitea/gitea` | 1024 | 256 | 125 | 425 |
| `keycloak/keycloak-db/postgres` | 384 | 192 | 67 | 438 |
| `keycloak/keycloak/keycloak` | 896 | 896 | 617 | 436 |
| `keycloak/keycloak-config/config-cli` | 384 | 384 | nicht gemessen | – |
| `keycloak/keycloak-db/plugin-barman-cloud` | 512 | 160 | 100 | 437 |
| `matrix/matrix-db/postgres` | 512 | 192 | 127 | 843 |
| `matrix/backup-*/*` `matrix/restore-*/*` `matrix/prune-*/*` `matrix/check-*/*` | 512 | 512 | nicht gemessen | – |
| `matrix/matrix-db/plugin-barman-cloud` | 512 | 160 | 51 | 832 |
| `matrix/matrix-db-pooler-rw/pgbouncer` | 128 | 64 | 32 | 401 |
| `whoami/whoami/whoami` | 64 | 64 | 4 | 804 |
| `argocd/argocd-applicationset-controller/applicationset-controller` | 256 | 64 | 34 | 417 |
| `argocd/argocd-application-controller/application-controller` | 1024 | 512 | 387 | 490 |
| `argocd/argocd-server/server` | 512 | 96 | 54 | 417 |
| `argocd/argocd-repo-server/repo-server` | 512 | 160 | 95 | 490 |
| `argocd/argocd-redis/redis` | 256 | 64 | 11 | 410 |
| `argocd/argocd-redis-secret-init/secret-init` | 64 | 64 | nicht gemessen | – |
<!-- memory-budget:end -->

## Siehe auch

- [Konfiguration](configuration.md): `memory_mib` und `memory_reserve_mib`
- [lab.sh](lab-sh.md#budget-befehl): der Befehl `budget`
- [Verify-Playbooks](verify-playbooks.md): `verify-budget.yml`
- [Sicherheitsmodell](../concepts/security-model.md): R12, `vm.overcommit_memory=1`
