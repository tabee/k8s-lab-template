---
title: Doku-Site
---

# Doku-Site docs.lab.example (Zensical, Mermaid)

## WAS und WARUM

**Was:** Die Doku in `docs/` (Tutorials, Anleitungen, Referenz, Erklärungen,
Lernpfad) und `gitops/README.md` erscheinen als Website unter
https://docs.lab.example, gebaut mit [Zensical](https://zensical.org).
Ein Pod im
Namespace `docs` holt jede Minute den Branch `main`, baut bei neuem Commit
neu und tauscht die Site atomar aus. Zugang wie bei whoami und Argo CD:
Traefik, Zertifikat der Lab-CA, NetworkPolicy (nur Traefik darf an den Pod).

**Warum:** Die Runbooks lesen sich im Browser besser als im Editor
(Navigation, Suche, Code kopieren), und sie sind immer auf dem Stand von
Git, ohne dass jemand etwas von Hand baut oder hochlädt. Der Graph zeigt,
welche Stufe auf welche verweist.

**Eselsbrücke:** *"Git ist die Druckerei, der Pod der Zeitungsjunge: er
schaut jede Minute, ob es eine neue Ausgabe gibt, und tauscht sie im
Briefkasten in einem Griff aus."*

## Wie es funktioniert

```text
git push (Branch main)
   |
   v  alle 60 s: git fetch per SSH (Deploy-Key aus Secret docs-repo)
Pod docs, Namespace docs
  builder (python:3.13.17-trixie)
     docs/build.sh -> /site/next
     mv --exchange /site/next /site/live   (atomar, nie halbe Site)
  web (static-web-server 2.44.1, Port 8080, liest /site/live)
   ^
   |  nur Traefik (NetworkPolicy docs-allow-traefik)
Traefik websecure :443, TLS docs-tls (cert-manager, ClusterIssuer lab-ca)
   ^
Browser https://docs.lab.example
```

- **Eine Quelle, keine Kopien.** Was auf der Site steht, liegt in `docs/`
  (Runbooks, Startseite, Theme). Daneben liegen Build-Skript
  und Pins, die `exclude_docs` von der Site fernhält. `zensical.toml` im
  Repo-Root legt Theme und Menü fest. `docs/reference/gitops-layout.md` ist ein Symlink auf
  `gitops/README.md` (eine Datei, zwei Orte). Aus
  `docs/learning-path/stage-5-traefik.md` wird
  `/learning-path/stage-5-traefik/`. Neue Seite = Markdown-Datei in `docs/` plus
  Eintrag unter `nav` in `zensical.toml`. Verweise zwischen Seiten als
  relativer Markdown-Link (`[Stufe 6](../learning-path/stage-6-certmanager.md)`):
  klickbar, im Graph und vom Build geprüft.
- **Kein eigenes Image, keine Registry.** Der builder nimmt das offizielle
  Python-Image und installiert Zensical beim ersten Build aus PyPI, exakt
  gepinnt mit Hashes (`docs/requirements.txt`, `pip --require-hashes`).
  Das Plugin kommt per HTTPS-Clone vom festen Commit (`ZG_COMMIT`) aus dem
  öffentlichen GitHub-Spiegel (`ZG_URL` in `docs/build.sh`). Pflege bleibt auf
  Gitea; der Build holt nie still von dort. Beides wird pro Pod einmal gebaut und
  unter `/tmp` gecacht (Neustart des Pods = neuer Download, ca. 1 Minute).
- **Frischer Server:** Ein Lauf von `ansible-playbook argocd.yml` legt
  Projekt, Namespace `docs` und Secret `docs-repo` an; Argo CD synct die App
  `docs`, sobald der Namespace da ist (retry 10 mit Backoff, wie
  argocd-ingress). Keine Reihenfolge von Hand, kein Image-Push.
- **Fehlgeschlagener Build** (Tippfehler in der Konfiguration, toter
  interner Link, PyPI weg):
  die alte Version bleibt online, der builder versucht es nach 60 s erneut.
  Nachsehen: `kubectl -n docs logs deploy/docs -c builder`.
- **Bereit** meldet der Pod erst nach dem ersten Build (Readiness auf `/`).
  Bis dahin liefert Traefik 503.
- **Kein alter Stand im Browser:** static-web-server schickt von sich aus
  `Cache-Control: max-age=86400` (ein Tag). Die Traefik-Middleware
  `no-cache` (`middleware.yaml`) ersetzt das durch `no-cache`: der Browser
  fragt jedes Mal kurz nach (meist Antwort 304, also billig) und zeigt nach
  einem Push sofort den neuen Stand.

### Warum so (Optionen)

| Option | Bewertung |
|--------|-----------|
| **Pod mit builder + Webserver (gewählt)** | Kein Registry, kein CI; Auto-Update nach Push (max. 60 s + Build); frischer Server ohne Handarbeit. Dafür lädt der Pod beim Start PyPI und das Plugin (Egress nötig). |
| Nur initContainer baut, dann Webserver | Einfacher, aber kein Auto-Update: neuer Stand erst nach Pod-Neustart (von Hand oder per Annotation). |
| Eigenes Image per CI bauen | Sauberster Laufzeit-Pod (nur statische Dateien), aber im Lab gibt es weder CI noch Registry; jeder Doku-Commit bräuchte einen Image-Build und ein Tag-Update im Git. |
| git-sync (k8s-Projekt) als Sidecar | Gute Git-Logik, aber dritter Container und das Bauen braucht trotzdem Python; der eigene 20-Zeilen-Loop reicht hier. |
| nginx statt static-web-server | Bräuchte ConfigMap und mehr Härtung für Port 8080 ohne root; static-web-server ist ein Binary ohne Shell, Konfiguration nur per Umgebung. |

Warum `mv --exchange` statt Symlink: static-web-server löst einen
Symlink-Root beim Start einmal auf und würde den Wechsel nie sehen. Der
Ordner-Tausch (`renameat2`, coreutils 9.7 im Image) ist atomar und wirkt
sofort.

## Wo liegt was

| Was | Wo |
|-----|----|
| Inhalte | `docs/{tutorials,how-to,reference,concepts,learning-path}/`, `docs/index.md`; `docs/reference/gitops-layout.md` = Symlink auf `gitops/README.md` |
| Abkürzungen (Tooltips) | `docs/_includes/abbreviations.md` (per Snippets an jede Seite angehängt, nicht auf der Site) |
| Site-Konfiguration, Menü, Theme | `zensical.toml` (Repo-Root), `docs/stylesheets/neon.css` |
| Build-Skript (Pod und lokal) | `docs/build.sh` |
| Pins Python-Pakete (mit Hashes) | `docs/requirements.txt` |
| Pin Plugin (Commit) | `docs/build.sh`, Variable `ZG_COMMIT` |
| Pins Images | `gitops/workloads/docs/deployment.yaml` |
| Argo-CD-App | `gitops/apps/docs.yaml` (Projekt lab) |
| Deployment, Service, IngressRoute, Certificate, NetworkPolicy | `gitops/workloads/docs/` |
| Namespace `docs` (PSA restricted) und Secret `docs-repo` | Ansible, Rolle `docs_site`, Werte `ansible/inventory/group_vars/all/docs.yml` |
| Repo-URL, Branch, Deploy-Key, known_hosts | `ansible/inventory/group_vars/all/argocd.yml` (gleicher Deploy-Key wie Argo CD, nur lesend) |
| Prüfung (nur lesend) | `ansible/verify-docs.yml` |

Das Secret `docs-repo` enthält den privaten Deploy-Key, deshalb nie im Git
(`no_log`, wie das Repo-Secret von Argo CD). Bleibt bei Ansible (Stufe 7):
es ist derselbe Deploy-Key wie für Argo CD, siehe [Stufe 7](../learning-path/stage-7-ksops.md).

## Benutzen

- Lesen: https://docs.lab.example (Eintrag in `/etc/hosts`:
  `192.168.122.50 docs.lab.example`, CA wie bei whoami importiert).
- Ändern: Markdown bearbeiten, committen, pushen. Nach spätestens
  ca. 2 Minuten ist die neue Version online.

Lokal ansehen, bevor man pusht (braucht python3 >= 3.11, git):

```bash
cd ~/projects/k8s-lab
rm -rf /tmp/docs-site && bash docs/build.sh /tmp/docs-site
python3 -m http.server -d /tmp/docs-site 8000   # http://localhost:8000
```

Lokal zählt alles in `docs/`, auch noch nicht Committetes; im Cluster nur,
was gepusht ist. Der Build schreibt nach `site/` und `.cache/` im Repo-Root
(beide in `.gitignore`).

## Mermaid, Selbst-Auslieferung und CSP {#mermaid-cdn}

Diagramme stehen als ```` ```mermaid ````-Block im Markdown. Zensical rendert sie
nicht beim Build: Der Browser zeichnet sie zur Anzeigezeit mit Mermaid. Das
Theme würde die Bibliothek von `unpkg.com` laden (schwebende Hauptversion, ohne
`integrity`-Hash), aber nur, wenn es im Browser noch kein `mermaid` gibt. Darum
liefert die Site Mermaid selbst aus ([ADR-0010](../concepts/decisions/0010-mermaid-cdn.md)):

- `docs/build.sh` lädt den npm-Tarball in der Version `MERMAID_VERSION`, prüft
  ihn gegen `MERMAID_TGZ_SHA512` und ruft `docs/vendor-mermaid.py` auf. Das
  Skript legt die Datei als `assets/vendor/mermaid/mermaid-<Version>.min.js` in
  die Site und setzt in jede Seite ein `<script src=… integrity="sha384-…"
  crossorigin="anonymous">` vor das Theme-Skript. Ein zweiter Lauf ändert nichts.
- **Mermaid aktualisieren:** `MERMAID_VERSION`, `MERMAID_TGZ_URL` und
  `MERMAID_TGZ_SHA512` an der **einen** Stelle in `docs/build.sh` ändern (die
  Prüfsumme steht in der Registry-Antwort `npm view mermaid@<Version> dist.integrity`),
  dazu die Zeile in [Versionen](../reference/versions.md).
- **Fail-closed:** Stimmt der Hash nicht oder ist der Download rot, bricht der
  Build ab. `MERMAID_SELF_HOST=0 bash docs/build.sh` baut bewusst ohne; dann
  gilt wieder das CDN des Themes (und `verify-docs.yml` mit
  `-e verify_docs_mermaid=false`).
- **Preis:** Die Datei ist rund 3,5 MB gross. Der Browser lädt sie einmal und
  hält sie im Cache.
- Ohne Skript im Browser bleiben Diagramme als Quelltext stehen; der Rest geht.

**Content-Security-Policy.** Die Datei `gitops/workloads/docs/middleware.yaml`
sendet `Content-Security-Policy-Report-Only`: `default-src 'none'`, Skripte nur
von der Site selbst. `'unsafe-inline'` bleibt in `script-src` und `style-src`,
weil das Theme Inline-Skripte setzt, die von Seite zu Seite verschieden sind;
eine Richtlinie mit Hashes ist deshalb nicht möglich. Im Modus Report-Only
blockiert der Browser nichts, er meldet Verstösse nur in seiner Konsole.
**Umstellen auf erzwingend** (bewusste, getrennte Änderung): Browser-Konsole
beim Durchklicken aller Seiten prüfen (keine Meldungen), dann den Schlüssel in
`middleware.yaml` von `Content-Security-Policy-Report-Only` in
`Content-Security-Policy` umbenennen, pushen, `verify-docs.yml` laufen lassen.
Die Notiz-Sites haben keine CSP ([Issue 38](https://github.com/tabee/k8s-lab-template/issues/38)).


## Eine Seite ergänzen {#seite-ergaenzen}

1. Markdown-Datei im passenden Ordner anlegen (Diátaxis: `tutorials/`,
   `how-to/`, `reference/`, `concepts/`). Kopf: `title:` im Front Matter, danach
   die Überschrift.
2. Eintrag unter `nav` in `zensical.toml`.
3. Überschriften mit Umlauten, auf die verlinkt wird, brauchen eine explizite ID
   (`## Netz-Kante {#netz-kante}`): Der Standard-Slug verwirft Umlaute und
   würde `#fuer-…` ergeben.
4. Code und Kommentare in Code-Blöcken auf Englisch, Text auf Deutsch.
5. Lokal bauen (siehe unten). Der Cluster baut mit `--strict`: eine Warnung
   (toter Link, fehlende Datei) lässt den Build scheitern, die alte Version bleibt.


## Neu bauen, Versionen ersetzen

- **Neu bauen erzwingen** (gleicher Commit): `kubectl -n docs rollout restart
  deployment docs`. Alter Pod liefert weiter, bis der neue fertig gebaut hat.
- **Zensical aktualisieren:** Version in `docs/requirements.txt` neu
  erzeugen (Befehl steht im Kopf der Datei), lokal `bash docs/build.sh`,
  committen, pushen. Der Werkzeug-Cache hängt am Hash der Pins, der builder
  installiert also von selbst neu.
- **Images:** Tags in `gitops/workloads/docs/deployment.yaml` (Python-Image
  in init und builder gleich halten). Vorher prüfen, dass das Python-Image
  coreutils >= 9.5 hat (`mv --exchange`).
- **Domain/Host:** `certificate.yaml`, `ingressroute.yaml`, `verify-docs.yml`.

## Prüfen

```bash
export KUBECONFIG=~/.kube/k3s-lab.kubeconfig
kubectl -n argocd get application docs          # Synced Healthy
kubectl -n docs get pods,certificate            # 2/2 Running, READY True
kubectl -n docs logs deploy/docs -c builder --tail=5   # "online: <commit>"
curl --cacert ~/.config/k8s-lab/lab-ca.crt -sS -o /dev/null -w '%{http_code}\n' https://docs.lab.example/   # 200
cd ~/projects/k8s-lab/ansible && ansible-playbook verify-docs.yml
```

NetworkPolicy von Hand prüfen (Pod aus Namespace whoami darf nicht an die
Doku). k3s (kube-router) **lehnt** geblockte Verbindungen ab (REJECT), darum
kommt sofort "Connection refused", kein Timeout. Räumt sich selbst weg
(`--rm`).

```bash
kubectl -n whoami run np-test --rm -i --restart=Never --image=docker.io/library/busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"np-test","image":"docker.io/library/busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec","command":["wget","-T","5","-qO-","http://docs.docs.svc/"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
# -> wget: can't connect to remote host (...): Connection refused   (so soll es sein)
```

## Rückbau (Rollback)

Ganz entfernen, per Git (Argo CD räumt die App-Objekte über den Finalizer
weg):

```bash
cd ~/projects/k8s-lab
git revert --no-edit <commit-der-sidequest>
git push
export KUBECONFIG=~/.kube/k3s-lab.kubeconfig
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd wait application/docs --for=delete --timeout=300s
cd ansible && ansible-playbook argocd.yml   # Projekt lab ohne docs
kubectl delete namespace docs               # Namespace + Secret gehoeren Ansible
```

Die Zeile `192.168.122.50 docs.lab.example` in `/etc/hosts` kann bleiben
oder von Hand weg. Nur die Site anhalten, ohne Rückbau: `docs.yaml` aus
`gitops/apps/` löschen und pushen (Namespace und Secret bleiben).

## Risiken und Grenzen

- Der builder braucht ausgehend PyPI und git.example.org (HTTPS) beim
  ersten Build pro Pod, dazu SSH zum Git-Server bei jedem Abruf. Ohne
  Internet startet ein neuer Pod nicht (alter läuft weiter, solange er
  lebt). `docs` hat
  Default-Deny für Egress ([Issue 5](https://github.com/tabee/k8s-lab-template/issues/5)) mit DNS, Git-SSH an die feste Adresse und HTTPS ins Internet
  (443 bleibt offen, weil kube-router keine Namen kennt); ändert sich die
  Adresse des Git-Servers, `bash scripts/lab.sh repo-egress --resolve`.
- Der builder führt `docs/build.sh` aus dem Repo aus: wer auf `main` pushen
  darf, bestimmt, was dort läuft. Grenzen: PSA restricted, kein
  Service-Account-Token, nur lesender Deploy-Key, 512 MiB Speicher.
- Zensical ist 0.0.x: Konfiguration und Verhalten können sich ändern,
  darum exakt gepinnt.
- Content-Security-Policy: die Doku-Site hat eine im Modus Report-Only, die
  Notiz-Sites haben keine ([Issue 38](https://github.com/tabee/k8s-lab-template/issues/38)); die Graph-Seite
  lädt ein Skript von unpkg.com (per SRI-Hash abgesichert).
