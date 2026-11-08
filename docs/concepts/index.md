---
title: Konzepte
---

# Konzepte

Hier steht das **Warum**. Die Seiten erklären, wie das Lab gebaut ist und
welche Eigenschaften es hat, ohne Schritt-für-Schritt-Anleitung. Wer etwas
tun will, findet das unter [Anleitungen](../how-to/index.md). Wer eine exakte
Angabe sucht, schaut in die [Referenz](../reference/index.md).

<div class="grid cards" markdown>

-   :lucide-layers:{ .lg .middle } __Architektur__

    ---

    Alle Bausteine auf einen Blick: Steuerrechner, VM, Namespaces, Backup-Ziel.

    [:lucide-arrow-right: Architektur](architecture.md)

-   :lucide-workflow:{ .lg .middle } __Bootstrap und GitOps__

    ---

    OpenTofu, Ansible, Argo CD: wer baut was, und wo übernimmt Git.

    [:lucide-arrow-right: Bootstrap und GitOps](bootstrap-and-gitops.md)

-   :lucide-network:{ .lg .middle } __Netz-Kante__

    ---

    Admin- und Ingress-Netz, nftables, der Weg der NodePorts.

    [:lucide-arrow-right: Netz-Kante](network-edge.md)

-   :lucide-badge-check:{ .lg .middle } __Zertifikate__

    ---

    Lab-CA mit nameConstraints, cert-manager, optionaler öffentlicher Issuer.

    [:lucide-arrow-right: Zertifikate](certificates.md)

-   :lucide-key-round:{ .lg .middle } __Geheimnisfluss__

    ---

    Von der Datei auf dem Steuerrechner bis zum Secret im Pod.

    [:lucide-arrow-right: Geheimnisfluss](secret-flow.md)

-   :lucide-database-backup:{ .lg .middle } __Backup und Restore__

    ---

    CNPG mit Barman nach rustfs, K8up mit restic, die Restore-Reihenfolge.

    [:lucide-arrow-right: Backup und Restore](backup-and-restore.md)

-   :lucide-shield-alert:{ .lg .middle } __Sicherheitsmodell__

    ---

    Bedrohungsmodell, Vertrauensgrenzen, ehrliche Restrisiken.

    [:lucide-arrow-right: Sicherheitsmodell](security-model.md)

-   :lucide-file-lock-2:{ .lg .middle } __Öffentliches Repo und Personendaten__

    ---

    Rechtlicher Rahmen (DSG, DSGVO), Prüfstufen und der Werkzeugvergleich.

    [:lucide-arrow-right: Öffentliches Repo und Personendaten](public-release-security.md)

-   :lucide-shield-check:{ .lg .middle } __Quellvertrauen und signierte Commits__

    ---

    Wem der Neuaufbau vertraut, was Argo CD selbst prüft und was `lab.sh` übernimmt.

    [:lucide-arrow-right: Quellvertrauen](source-trust.md)

-   :lucide-scroll-text:{ .lg .middle } __Entscheidungen (ADR)__

    ---

    Warum etwas so gebaut ist und nicht anders.

    [:lucide-arrow-right: Entscheidungsprotokoll](decisions/index.md)

</div>
