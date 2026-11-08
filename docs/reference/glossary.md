---
title: Glossar
---

# Glossar

Begriffe des Labs in alphabetischer Reihenfolge. Die Kurzformen (zum Beispiel
GitOps, PSA, PITR) erklären sich im ganzen Text auch beim Darüberfahren.

**ACME / DNS-01**
:   Protokoll für öffentliche Zertifikate. Beim Verfahren DNS-01 beweist ein
    Eintrag im DNS die Kontrolle über einen Namen. Im Lab nur für die optionale
    [öffentliche Probe](../how-to/public-certificate.md) (Issuer `lab-acme`).

**Abnahme**
:   `bash scripts/lab.sh acceptance`: zwölf Phasen, die beweisen, dass das Lab trägt und
    dass sich Backups zurückspielen lassen ([Abnahme-Prüfungen](acceptance-checks.md)).

**Admin-Netz / Ingress-Netz**
:   Die beiden Netze der Kante: Wer die Verwaltung (SSH, API, Argo-CD-Oberfläche auf
    Port 8444) erreicht, und wer 80/443 erreicht ([Netz-Kante](../concepts/network-edge.md)).

**age**
:   Einfaches Verschlüsselungswerkzeug. Der age-Schlüssel entschlüsselt die
    SOPS-Dateien ([Geheimnis-Fluss](../concepts/secret-flow.md)).

**AppProject**
:   Argo-CD-Objekt, das Quell-Repos, Ziel-Namespaces und erlaubte Objektarten
    einer Gruppe von Applications begrenzt. Im Lab gibt es `lab`, `platform` und
    `notes` ([Bootstrap und GitOps](../concepts/bootstrap-and-gitops.md#zwei-projekte-zwei-vertrauensstufen)).
    Ein Projekt verhindert Fehler, keinen Angreifer mit Schreibrecht auf `main`.

**Application / ApplicationSet**
:   Objekte von Argo CD: eine Application verbindet einen Ordner in Git mit einem
    Namespace im Cluster; ein ApplicationSet erzeugt Applications aus einer Liste
    (im Lab: die Notiz-Sites).

**App-of-Apps**
:   Muster: eine Root-Application (`root`) liest einen Ordner voller
    Applications ([gitops/](gitops-layout.md)).

**Argo CD**
:   GitOps-Werkzeug. Liest Git und gleicht den Cluster daran an
    ([Bootstrap und GitOps](../concepts/bootstrap-and-gitops.md)).

**Barman Cloud Plugin**
:   Plugin für CloudNativePG: archiviert WAL und Basis-Backups in einen
    S3-Speicher ([Backup und Restore](../concepts/backup-and-restore.md)).

**Bucket**
:   Behälter in einem S3-Speicher. Im Lab zwei: `cnpg-k3s-lab` (Datenbanken)
    und `k8up-k3s-lab` (Dateien).

**CA (Lab-CA)**
:   Die eigene Zertifizierungsstelle des Labs. Ihr Zertifikat trägt kritische
    nameConstraints: sie darf nur Namen unter der Lab-Domain ausstellen
    ([Zertifikate](../concepts/certificates.md)).

**cert-manager**
:   Stellt Zertifikate aus und erneuert sie.

**cloud-init**
:   Erstkonfiguration der VM beim ersten Start (Benutzer, SSH-Schlüssel).

**CNPG (CloudNativePG)**
:   Operator für PostgreSQL in Kubernetes. Im Lab: `pg-lab` (Übung, drei Instanzen) und
    `gitea-db` (zwei Instanzen).

**Fallschirm**
:   Der Export der VM-Platte vor `down`, mit dem man die alte VM zurückholen
    kann ([Export und Wiederherstellung](../how-to/export-and-restore-vm.md)).

**Flannel**
:   Das Netz-Plugin (CNI), das k3s für das Pod-Netz mitbringt (Interfaces `cni0`
    und `flannel.1`). Es verbindet die Pods; die NetworkPolicies setzt daneben
    kube-router um ([Ports und Netze](ports-and-networks.md)).

**GitOps**
:   Der Soll-Zustand steht in Git, ein Werkzeug gleicht den Ist-Zustand
    daran an. Änderungen laufen über Git, nicht über `kubectl`.

**HSTS**
:   HTTP Strict Transport Security: ein Header, mit dem der Browser für eine
    Zeit nur noch HTTPS zum Host benutzt. Traefik setzt ihn im Lab für ein Jahr
    ([Sicherheitsmodell](../concepts/security-model.md)).

**K8up**
:   Backup-Operator auf Basis von restic. Sichert die Dateien von Gitea
    (`backups.k8up.io`).

**KSOPS**
:   Kustomize-Erweiterung, mit der der Repo-Server von Argo CD SOPS-Dateien
    beim Rendern entschlüsselt.

**k3s**
:   Schlanke Kubernetes-Verteilung. Im Lab auf einer VM, ohne eigenes Traefik.

**kube-router**
:   Netzwerkrichtlinien-Umsetzung in k3s. Die erste Verbindung eines neuen Pods
    wird etwa eine Sekunde lang abgewiesen
    ([Fehlersuche](../how-to/troubleshooting.md#kube-router-erste-verbindung)).

**libvirt**
:   Verwaltung der VM auf dem Steuerrechner (QEMU/KVM).

**nameConstraints**
:   Zertifikatserweiterung, die einer CA verbietet, Namen ausserhalb einer Zone
    auszustellen.

**NetworkPolicy**
:   Regel, die den Verkehr zwischen Pods einschränkt. Jeder Namespace des Labs bringt
    seine eigene mit.

**NodePort**
:   Dienst-Typ, der einen Port auf dem Knoten öffnet. Von aussen sind alle
    NodePorts zu.

**nftables**
:   Firewall der VM, Tabelle `inet host_filter`.

**OpenTofu**
:   Freie Fortführung von Terraform. Baut und zerstört nur die VM.

**PITR (Point-in-Time-Recovery)**
:   Wiederherstellen einer Datenbank auf einen Zeitpunkt (Basis-Backup plus WAL).

**Pooler / PgBouncer**
:   Verbindungsbündler vor dem Cluster. Im Lab Modus `session`, mit
    zwei Pods bei `pg-lab`.

**PSA (Pod Security Admission)**
:   Kubernetes prüft beim Anlegen eines Pods Sicherheitsprofile. Alle Namespaces
    des Labs erzwingen `restricted`.

**Quadlet**
:   Podman-Weg, Container als systemd-Dienste zu beschreiben. rustfs läuft so
    (rootless).

**RBAC**
:   Role-Based Access Control: Kubernetes erlaubt Aktionen über Rollen und
    Bindungen. Im Lab gibt es kein RBAC pro Person, der Admin-Zugang ist die
    kubeconfig mit Cluster-Admin (Restrisiko R15 im
    [Sicherheitsmodell](../concepts/security-model.md#restrisiken)).

**restic**
:   Backup-Werkzeug, das K8up benutzt (Aufbewahrung 14 täglich, 8 wöchentlich,
    6 monatlich).

**rustfs**
:   S3-kompatibler Speicher auf dem Steuerrechner, Ziel aller Backups
    ([Ports und Netze](ports-and-networks.md)).

**secretbox**
:   Verschlüsselung der Kubernetes-Secrets in etcd (XSalsa20-Poly1305). Eine
    frische VM startet damit.

**Self-Heal**
:   Einstellung einer Argo-CD-Application (`selfHeal: true`): Weicht der Cluster
    von Git ab, stellt Argo CD den Stand aus Git wieder her. Handarbeit im Cluster
    hält dann nicht ([Bootstrap und GitOps](../concepts/bootstrap-and-gitops.md)).

**ServerSideApply**
:   Anwendungsweise von Argo CD, nötig für grosse CRDs.

**ServiceLB**
:   Der eingebaute Lastverteiler von k3s: Er startet für einen Service vom Typ
    `LoadBalancer` einen Pod pro Knoten (`svclb-*`) und leitet Verkehr per
    hostPort an den Service. Im Lab trägt er Traefik
    ([Netz-Kante](../concepts/network-edge.md)).

**SniStrict**
:   Traefik-Einstellung: Anfragen ohne passenden SNI-Namen werden abgelehnt.

**SOPS**
:   Verschlüsselt die Werte einer YAML-Datei, Schlüssel und Struktur bleiben lesbar.

**Steuerrechner**
:   Der PC, auf dem du `lab.sh` ausführst und der rustfs betreibt.

**STRIDE**
:   Eine Einteilung von Bedrohungen in sechs Klassen: Spoofing, Tampering,
    Repudiation, Information Disclosure, Denial of Service, Elevation of
    Privilege. Die Tabellen im [Sicherheitsmodell](../concepts/security-model.md#bedrohungen-und-gegenmassnahmen)
    nutzen sie als Spalte.

**Sync-Wave**
:   Annotation `argocd.argoproj.io/sync-wave`: legt innerhalb **einer**
    Application die Reihenfolge fest, in der Argo CD Objekte anwendet. Zwischen
    den Apps nutzt das Lab bewusst keine Sync-Waves, sondern `retry`
    ([ADR-0003](../concepts/decisions/0003-retries-instead-of-sync-waves.md)).

**Traefik**
:   Ingress-Controller des Labs; Ports 80 und 443, Argo CD auf 8444.

**ValidatingAdmissionPolicy**
:   Eingebaute Kubernetes-Regel (CEL), die der API-Server vor dem Speichern prüft.
    Im Lab erzwingt sie, dass Zertifikate der Lab-CA nur Namen unter der
    Lab-Domain tragen ([Zertifikate](../concepts/certificates.md)).

**Vertrauensgrenze**
:   Eine Stelle, an der Daten oder Rechte von einem Bereich mit weniger
    Vertrauen in einen mit mehr übergehen (zum Beispiel Steuerrechner zur VM).
    Das Lab benennt sie als TB1 bis TB5 im
    [Sicherheitsmodell](../concepts/security-model.md#vertrauensgrenzen).

**Wächter**
:   Prüfwerkzeug des Exports. Bricht ab, wenn die öffentliche Kopie Persönliches
    oder Geheimes enthält ([Öffentliche Kopie](../how-to/public-release.md)).

**WAL**
:   Write-Ahead-Log von PostgreSQL. Die Archivierung ist Grundlage von PITR.

**Zensical**
:   Der Generator dieser Doku-Site ([Doku-Site](../how-to/docs-site.md)).
