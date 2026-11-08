# secrets/

Hier liegen **nur** mit SOPS verschluesselte Secrets (`*.sops.yaml`) und
die Kustomize-Dateien, die Argo CD zum Entschluesseln braucht. Ein Ordner
pro Namespace, eine Application pro Ordner (`gitops/apps/secrets-<ns>.yaml`).

```text
secrets/
  cert-manager/
    kustomization.yaml       <- Kustomize: nur der Generator
    ksops.yaml               <- KSOPS-Generator: Liste der *.sops.yaml
    lab-ca.sops.yaml <- CA der Lab-PKI (verschluesselt)
  db-lab/                    <- Stufe 8b (CNPG, Uebungs-Datenbank)
    kustomization.yaml
    ksops.yaml
    backup-s3-creds.sops.yaml <- S3-Zugang fuer Barman (aus der env-Datei von Stufe 8a)
  gitea/                     <- Stufe 8c (Gitea, K8up)
    kustomization.yaml
    ksops.yaml
    backup-s3-creds.sops.yaml <- S3-Zugang fuer Barman (gitea-db), gleicher Schluessel wie db-lab
    gitea-db-owner.sops.yaml <- Besitzer der Datenbank gitea (basic-auth)
    gitea-admin.sops.yaml    <- erster Gitea-Admin (username, password)
    k8up-s3-creds.sops.yaml  <- S3-Zugang fuer K8up (nur Bucket k8up-k3s-lab)
    k8up-repo.sops.yaml      <- restic-Repo-Passwort
```

Regeln:

- Verschluesselt wird nur `data`/`stringData` (`.sops.yaml` im Repo-Root),
  Name, Namespace, Labels und Annotationen bleiben lesbar.
- Jedes Secret hat `argocd.argoproj.io/sync-options: Prune=false,Delete=false`:
  Argo CD legt an und aktualisiert, loescht aber nie.
- `.gitignore` laesst hier nur `*.sops.yaml`, `kustomization.yaml`,
  `ksops.yaml` und diese Datei zu. Klartext-Dateien bleiben lokal.
- Oeffentliche Kopie des Repos (z.B. GitHub): diesen Ordner und
  `gitops/apps/secrets-*.yaml` weglassen, sonst nichts.

Vorlagen: zu jeder `*.sops.yaml` gibt es eine `*.sops.yaml.example` mit
Platzhaltern statt Werten (`@datei:NAME`, `@env:NAME:SCHLUESSEL`,
`@ca:NAME:SCHLUESSEL`; der Name steht in `docs/reference/secrets-map.md`).
`bash scripts/lab.sh init` rendert daraus die `*.sops.yaml` aus den Dateien
unter `~/.config/` und verschluesselt sofort. Eine vorhandene `*.sops.yaml`
wird nie ueberschrieben. `.gitignore` laesst die Vorlagen zu.

Runbook: `docs/learning-path/stage-7-ksops.md`. Pruefen: `ansible-playbook verify-ksops.yml`.

Secret aus einer lokalen env-Datei (z.B. S3-Zugang fuer CNPG aus Stufe 8a):
`ansible/scripts/sops-secret.sh from-env NS NAME ~/.config/k8s-lab/s3-cnpg-k3s-lab.env`
(Runbook: `docs/learning-path/stage-8a-backup-target.md`).
