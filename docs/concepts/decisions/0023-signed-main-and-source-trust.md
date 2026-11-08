---
title: "ADR-0023: Signierte Commits auf main und Quellvertrauen beim Neuaufbau"
---

# ADR-0023: Signierte Commits auf main und Quellvertrauen beim Neuaufbau

**Status:** angenommen (Issue 6, Entscheidung des Betreibers aus Issue 51 und Issue 26)

## Kontext

Schreibrecht auf `main` ist Cluster-Admin ([Sicherheitsmodell, R1](../security-model.md)). Die AppProjects
(`root`, `platform`, `lab`, `default`) halten Fehler und Workloads in Grenzen, nicht einen Angreifer mit
Schreibrecht. Dazu kommt der Neuaufbau aus einer **Kopie**: ein privates GitHub-Repo, gespeist vom privaten Gitea
([ADR-0022](0022-private-secrets-repo.md)). Wer das GitHub-Konto übernimmt, darf das Lab nicht übernehmen können.

Argo CD prüft Commit-Signaturen seit der Quellintegrität (`AppProject.spec.sourceIntegrity.git.policies[]`) mit
**GnuPG**. SSH-Signaturen unterstützt es nicht (in Chart 10.11 / Argo CD 3.5 gibt es im CRD kein SSH-Feld;
der Wunsch ist [argo-cd#8733](https://github.com/argoproj/argo-cd/issues/8733)). Das Feld `signatureKeys` ist
veraltet.

## Entscheidung

1. **Ein Signaturformat: SSH.** Commits auf `main` sind mit dem vorhandenen ed25519-Schlüssel signiert. Die erlaubten
   Schlüssel stehen in `.gitea/allowed_signers`, die Liste kommt immer aus dem **Eltern-Commit**.
2. **Gitea setzt es durch:** Branch-Schutz (signierte Commits verlangen, kein Force-Push) und der Workflow
   `signature-check.yml` als zweite Linie ([SSH-Commit-Signatur](../../how-to/signed-commits.md)).
3. **Quellvertrauen in `lab.sh`:** `up`, `rebuild` und `preflight` holen `main` von `repo_url` und prüfen mit
   `scripts/lab-trust.sh`, dass der Commit der **letzte vertraute Commit oder ein Nachfahre** ist, dessen Commits alle
   von einem erlaubten Signer stammen. Der vertraute Commit liegt **ausserhalb von Git**
   (`~/.config/k8s-lab/trusted-head`, Modus 0600). Bei Abweichung oder fehlender Signatur: Abbruch mit einer klaren
   Meldung, ausser `--trust-override` plus getippter Bestätigung. Am Ende des Laufs eine zweite Prüfung.
4. **`source_trust: auto | on | off`** in `lab.yaml`. `auto` ist an, sobald ein vertrauter Commit eingetragen ist oder
   `repo_url` bei einem öffentlichen Anbieter liegt (github.com, gitlab.com, codeberg.org, bitbucket.org). Wer
   `repo_url` auf GitHub stellt, muss deshalb zuerst `lab.sh trust init COMMIT` sagen.
5. **Argo CD bleibt bei dem, was es kann.** Die AppProject-Härtung bleibt. Eine eigene SSH-Prüfung im Cluster gibt es
   nicht; Argo-CD-eigene Prüfung ist nur mit GnuPG möglich.

## Verworfene Alternativen

| Option | Warum nicht |
|---|---|
| GnuPG-Signaturen und `sourceIntegrity` in Argo CD | Argo CD prüft dann jeden Sync, aber der Betreiber braucht einen zweiten Schlüsseltyp. Ein Commit trägt nur **eine** Signatur: Gitea-Workflow, `lab-trust.sh` und Argo CD müssten beide Formate kennen, und zwei Listen driften auseinander. Neubewertung: [Issue 70](https://github.com/tabee/k8s-lab-template/issues/70). |
| Zwei Signaturen pro Commit (SSH und GPG) | Git kennt eine Signatur pro Commit. |
| Nur Workflow in Gitea, keine Prüfung beim Neuaufbau | Der Neuaufbau liest die Kopie, nicht Gitea. Ein übernommenes GitHub-Konto umginge die Prüfung. |
| Anker im Repo (zum Beispiel `trusted-head` als Datei) | Wer das Repo schreibt, ändert den Anker. |
| Alle Commits der Historie prüfen | Die alte Historie ist unsigniert und wird nicht umgeschrieben (Issue 6). Der Anker legt fest, ab wann die Signatur gilt. |

## Folgen

- Der erste Anker ist eine bewusste Handlung (`trust init`, getippte Bestätigung).
  [Anleitung GitHub-Spiegel](../../how-to/github-push-mirror.md).
- **Pin statt Fenster:** Während `up` und `rebuild` liest Argo CD den geprüften Commit (Root-Anwendung auf der
  Commit-ID, Kustomize-Patches für alle Kind-Anwendungen) und wird nach der bestandenen Zweitprüfung wieder auf
  `main` gestellt. Eine Bewegung von `main` während des Laufs wird so **verhindert**, nicht nur erkannt. Bei
  fehlgeschlagener Zweitprüfung bleibt der Pin (`lab.sh trust release` löst ihn nach deiner Prüfung). Nicht
  gepinnt: ein getrenntes Secrets-Repo und das Repo-Secret der Doku-Site.
  Verworfen: ein Pin über ein Helm-Chart oder `argocd app set` (nicht deklarativ, Ansible würde ihn überschreiben)
  und ein Pin nur auf `root` (die Kind-Anwendungen läsen weiter `main`).
- **Restrisiko:** ein signierter Commit von dir kann alles anlegen. Der Signierschlüssel braucht Passphrase und Agent.
- Web-Merges in Gitea bringen unsignierte Commits ([Issue 73](https://github.com/tabee/k8s-lab-template/issues/73)).
- Konzept und Grenzen: [Quellvertrauen](../source-trust.md).
