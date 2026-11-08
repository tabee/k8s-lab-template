# Stufe 4: Argo CD (GitOps)

!!! abstract "Lernpfad, Stufe 4"
    Runbook für `argocd.yml`, die Rolle `argocd_bootstrap`, `verify-argocd.yml`
    und den Ordner `gitops/`. Hier stehen keine Secrets, vom Deploy-Key nur der
    Pfad. Heute gültig: [Bootstrap und GitOps](../concepts/bootstrap-and-gitops.md)
    (Erklärung) und [GitOps-Ordner](../reference/gitops-layout.md) (Referenz).

!!! tip "Eselsbrücke"
    **Ansible zündet die Rakete, danach fliegt sie mit Git als Steuerung.**

## Was und warum

- **GitOps:** Der gewünschte Zustand des Clusters steht in Git (`gitops/`).
  Ein Controller im Cluster vergleicht ihn laufend mit dem echten Zustand und
  gleicht ab. Jede Änderung ist ein Commit: nachvollziehbar, reviewbar,
  per `git revert` rückgängig zu machen.
- **Pull statt Push:** Nicht der Laptop oder eine CI schiebt mit Admin-Rechten
  ins Cluster, sondern Argo CD holt sich die Manifeste selbst aus Git. Nach
  aussen braucht es dafür nur einen Lese-Zugang zum Repo, keinen
  Cluster-Zugang.
- **Self-Heal:** Weicht der Cluster von Git ab (z. B. `kubectl scale` von Hand),
  setzt Argo CD den Git-Stand zurück. **Prune:** Was aus Git verschwindet,
  wird im Cluster gelöscht.
- **App-of-Apps:** Ansible legt genau eine Application an, `root`. Sie zeigt
  auf `gitops/apps/`; jede Datei dort ist wieder eine Application (z. B.
  `whoami`), die auf `gitops/workloads/<name>/` zeigt. Neue App = neue Datei
  in `gitops/apps/`, kein Ansible-Lauf nötig.
- **Read-only Deploy-Key:** Argo CD bekommt einen eigenen SSH-Schlüssel, der in
  Gitea nur für dieses Repo und nur lesend freigeschaltet ist
  (Fingerprint `SHA256:YOUR-FINGERPRINT`). Wird der
  Cluster kompromittiert, kann damit niemand ins Repo schreiben.
- **Henne-Ei:** Argo CD kann sich nicht selbst aus Git installieren, solange es
  noch nicht läuft. Darum macht Ansible genau den Bootstrap (Namespace, Helm-
  Chart, Repo-Secret, AppProject, Root-App). Alles danach kommt aus Git.
  Argo CD selbst bleibt bewusst bei Ansible/Helm (Upgrade = Chart-Version in
  `group_vars/all/argocd.yml` erhöhen, `argocd.yml` laufen lassen).

Regel ab jetzt: **Änderungen via Git, kubectl nur zum Schauen.** Was per
kubectl an Apps geändert wird, dreht Self-Heal zurück.

## Abhängigkeit: WireGuard-Tunnel auf dem Host

Die Pods erreichen `git.example.org` nur über den
WireGuard-Tunnel des Hosts (NAT aus dem libvirt-Netz). **Ist der Tunnel unten,
kann Argo CD nicht mehr aus Git lesen:** Apps zeigen `ComparisonError` bzw.
`Unknown`, neue Commits kommen nicht an. Laufende Pods bleiben stehen, es wird
nichts gelöscht. Prüfen:

```bash
sudo wg show                       # Tunnel aktiv, letzter Handshake frisch?
ssh 192.168.122.50 "timeout 3 bash -c '</dev/tcp/git.example.org/22' && echo reachable"
```

## Voraussetzungen auf dem Host

Die Distribution des Hosts ist nicht bekannt; die Befehle sind für
Ubuntu/Debian, auf anderen Distros das passende Paket nehmen.

1. **Helm v4** (das Modul `kubernetes.core.helm` ruft das Binary auf):

   ```bash
   cd /tmp
   curl -fsSLO https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz
   curl -fsSL https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz.sha256sum | sha256sum -c -
   tar xzf helm-v4.3.1-linux-amd64.tar.gz
   sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
   helm version --short
   ```

2. **Collection kubernetes.core** (steht nach Edit 1 in `requirements.yml`):
   `cd ~/projects/k8s-lab/ansible && ansible-galaxy collection install -r requirements.yml`
3. **Python-Paket `kubernetes`** für genau das Python, mit dem Ansible läuft
   (`ansible --version`, Zeile "python version"):
   - Ansible aus apt: `sudo apt install python3-kubernetes`
   - Ansible per pipx: `pipx inject ansible-core kubernetes` (bzw. `ansible`)
   - Ansible in einem venv: `pip install kubernetes` im venv
4. **kubectl** (für UI-Zugang und Übung) und für die Zwischenablage
   `wl-clipboard` (Wayland) oder `xclip` (X11): `sudo apt install wl-clipboard`
5. **Deploy-Key** liegt unter `~/.ssh/argocd-k8s-lab` mit Rechten `0600`
   (`chmod 600 ~/.ssh/argocd-k8s-lab`); der Public Key ist in Gitea als
   Deploy-Key "Argo CD" (nur lesen) eingetragen.

Optional: das Helm-Plugin `helm-diff`. Ohne es meldet Ansible "The default
idempotency check can fail to report changes in certain cases". Da Chart-
Version und Values fest sind, reicht der Standardvergleich; die Warnung ist
erwartet.

Das Preflight der Rolle prüft alles davon (helm, Python-Paket, Kubeconfig,
Key-Rechte, Host-Keys, API erreichbar) und bricht mit deutscher Meldung ab.

## Ablauf

Alle Befehle aus `~/projects/k8s-lab/ansible`, falls nicht anders angegeben.

1. **Snapshot** der VM (Rückweg):
   `virsh -c qemu:///system snapshot-create-as k3s-lab vor-stufe4 --atomic`
2. **Host-Keys des Git-Servers** ins Inventory. Ohne sie lehnt Argo CD die
   SSH-Verbindung ab.

   ```bash
   ssh-keyscan git.example.org
   ```

   Nur die Zeilen ohne `#` übernehmen, sie beginnen mit
   `git.example.org `. Gegenprüfen mit dem Schlüssel, dem du beim
   Pushen schon vertraust (Fingerprints müssen gleich sein):

   ```bash
   ssh-keyscan git.example.org 2>/dev/null | grep -v '^#' | ssh-keygen -lf -
   ssh-keygen -lF 'git.example.org'
   ```

   Dann in `inventory/group_vars/all/argocd.yml` eintragen:

   ```yaml
   argocd_repo_known_hosts:
     - "git.example.org ssh-ed25519 AAAA..."
   ```

3. **Zuerst `gitops/` committen und pushen** (Branch `main`). Die Root-App zeigt
   auf `gitops/apps` im Repo; fehlt der Ordner dort, bleibt sie mit
   "app path does not exist" hängen.

   ```bash
   cd ~/projects/k8s-lab && git status -uall && git add -A && git commit && git push
   ```

4. **Check-Lauf:** `ansible-playbook argocd.yml --check --diff`
   (AppProject, Root-App und PSA-Probe werden im Check-Lauf übersprungen,
   siehe unten.)
5. **Echter Lauf:** `ansible-playbook argocd.yml` (Helm wartet bis alle Pods
   bereit sind, Timeout 10 Minuten).
6. **Zweiter Lauf:** `ansible-playbook argocd.yml` muss `changed=0` zeigen.
7. **Prüfen:** `ansible-playbook verify-argocd.yml` (wartet bis root und
   whoami `Synced`/`Healthy` sind, max. 5 Minuten).
8. **UI:** seit Stufe 6c https://argocd.lab.example:8444 (über Traefik,
   Zertifikat der Lab-CA, siehe [Stufe 6c](stage-6c-argocd-ingress.md)).
   Notausgang ohne Traefik (argocd-server spricht seit 6c nur HTTP):

   ```bash
   export KUBECONFIG=~/.kube/k3s-lab.kubeconfig
   kubectl -n argocd port-forward svc/argocd-server 8080:80
   ```

   Dann http://localhost:8080 öffnen (nur lokal, der Tunnel ist von kubectl
   verschlüsselt).
9. **Admin-Passwort** direkt in die Zwischenablage, ohne es anzuzeigen:

   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | wl-copy
   # X11 instead of Wayland: ... | base64 -d | xclip -selection clipboard
   ```

   Login als `admin`. Danach unter "User Info" -> "Update Password" ein
   eigenes Passwort setzen (Passwortmanager) und das Initial-Secret löschen:
   `kubectl -n argocd delete secret argocd-initial-admin-secret`
   (Ausnahme von "kubectl nur zum Schauen": das Secret gehört zum Bootstrap,
   nicht zu Git.)

## Übung: Self-Heal beobachten

```bash
export KUBECONFIG=~/.kube/k3s-lab.kubeconfig
kubectl -n whoami scale deployment whoami --replicas=3
kubectl -n whoami get deployment whoami -w
```

Innerhalb weniger Sekunden setzt Argo CD `replicas` wieder auf 1 (Git-Stand);
in der UI erscheint ein Sync-Eintrag. Der richtige Weg für 3 Replikas:
`gitops/workloads/whoami/deployment.yaml` ändern, committen, pushen.
Argo CD fragt Git standardmässig alle ~3 Minuten ab (oder "Refresh" in der UI).

## PSA-Prüfung (Namespace argocd ohne Ausnahme)

- Der Namespace `argocd` trägt `enforce`/`audit`/`warn` = `restricted`
  (Version `latest`); `gitops/workloads/whoami/namespace.yaml` ebenso.
  Nur `kube-system` ist clusterweit ausgenommen (Stufe 3).
- **Nachweis:** Die Rolle und `verify-argocd.yml` schicken einen absichtlich
  unsicheren Pod (`privileged: true`) per Server-Dry-Run (`check_mode: true`,
  es entsteht nichts). Der API-Server muss ihn mit "violates PodSecurity"
  ablehnen, sonst bricht der Lauf ab.
- Die Security-Contexts des Charts erfuellen `restricted` bereits; ohne das
  wären Helms `wait` und `verify-argocd.yml` an fehlenden Pods gescheitert.
- Von Hand, zeigt Warnungen für laufende Pods, die verstossen würden:
  `kubectl label --dry-run=server --overwrite ns argocd pod-security.kubernetes.io/enforce=restricted`
  (keine Warnung = alles ok).

## Check-Modus: Grenzen

- AppProject und Application sind CRDs, die erst das Helm-Chart anlegt. Beim
  ersten `--check` gibt es sie noch nicht, darum laufen diese Tasks und die
  PSA-Probe nur mit `when: not ansible_check_mode`.
- Das Repo-Secret hat `no_log: true` und `diff: false`: auch `--diff` und
  `-vvv` zeigen den Schlüssel nicht.

## Entscheidungen

- **Chart** `argo-cd` 10.11.1 (Argo CD v3.5.6), gepinnt in
  `group_vars/all/argocd.yml`. Argo CD 3.5 ist gegen Kubernetes 1.33 bis 1.36
  getestet.
- **Dex aus:** kein SSO im Lab, nur lokaler `admin`.
- **Notifications aus:** kein Ziel (Mail/Chat) konfiguriert, also kein Controller nötig.
- **ApplicationSet bleibt:** lässt sich im Chart nicht abschalten (folgt dem
  Upstream-Manifest); klein gehalten, App-of-Apps braucht ihn nicht.
- **Kein Ingress** (Verlauf, Stand Stufe 4: Traefik war noch aus, die UI lief nur per Port-Forward). Heute läuft die Oberfläche
  über Traefik, siehe [Stufe 6c](stage-6c-argocd-ingress.md).
- **NetworkPolicies des Charts bleiben an:** sie regeln nur eingehenden
  Verkehr; der Repo-Server darf weiter nach aussen auf Port 2222.
- **AppProject `lab`:** nur dieses Repo als Quelle, nur dieses Cluster als
  Ziel, clusterweit nur Namespaces erlaubt.
- **Root-App mit Finalizer** `resources-finalizer.argocd.argoproj.io`:
  Löschen der App löscht auch ihre Ressourcen (kaskadierend). Die
  Kubernetes-Warnung "prefer a domain-qualified finalizer name" ist erwartet;
  der Name ist von Argo CD so vorgegeben.

## Entscheidung: Deploy-Key bleibt bei Ansible

Der Deploy-Key bleibt bei Ansible (Stufe 7): Argo CD braucht ihn, bevor es
überhaupt etwas aus dem Git lesen und entschlüsseln kann (Henne-Ei).
Siehe [Stufe 7](stage-7-ksops.md).

Das `default`-AppProject und das Ziel `*` des Projekts `lab` (auch `argocd`) sind weiter offen
([Issue 6](https://github.com/tabee/k8s-lab-template/issues/6)).

## Rückweg

Sanft (in dieser Reihenfolge, sonst blockieren Finalizer):

```bash
export KUBECONFIG=~/.kube/k3s-lab.kubeconfig
kubectl -n argocd delete application root      # deletes whoami cascading
kubectl get ns whoami                          # wait until it is gone
helm -n argocd uninstall argocd
kubectl delete namespace argocd
kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io
```

Hart: `virsh -c qemu:///system snapshot-revert k3s-lab vor-stufe4`.
Wird Argo CD ganz aufgegeben, den Deploy-Key "Argo CD" in Gitea entfernen.

## Abschluss (2026-10-24)

- Bootstrap erfolgreich: 1. Lauf changed=6, 2. Lauf changed=0,
  `verify-argocd.yml` ok=12 failed=0; root und whoami Synced/Healthy.
- Check-Modus beim Erstlauf scheiterte zweimal, beide Male gleiche Ursache
  wie bei auditd (Stufe 3): Helm-Repo und Namespace existierten nur
  "simuliert". Lösung: `register` + `when: not (ansible_check_mode and
  <var> is changed)` (Commit 0a3c2d5).
- Admin-Passwort per `wl-copy` geholt, geändert, Initial-Secret gelöscht.
- Self-Heal: `kubectl scale --replicas=3` nach ca. 1 s zurück auf Git-Stand.
- GitOps-Übung: `replicas: 2` in Git (7f60d5e), nach Refresh im Cluster.
- Eselsbrücke: "Was nicht in Git steht, gibt es nicht."
