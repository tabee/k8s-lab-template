# AGENTS.md

Instructions for AI coding agents and human contributors. Keep this file short; details live in the
docs linked at the bottom. `tests/agents-tests.sh` fails when a path or command named here no longer exists.

## Purpose and audience

k8s-lab builds a single-node k3s lab in a libvirt VM from code: OpenTofu creates the VM, Ansible hardens
the host and installs k3s and Argo CD, Argo CD then delivers everything else from Git (Traefik, cert-manager
with a private CA, SOPS/age with KSOPS, CloudNativePG with barman to rustfs, K8up, Gitea, Matrix (Synapse and Element Web), Keycloak single sign-on for both, a docs site).
It is a reproducible teaching and security-review target for pentesters, security engineers and Kubernetes
trainers. Treat it as a security reference: correctness and honesty about trade-offs beat features.
Licence: AGPL-3.0-only (`LICENSE`).

Release goals: a stranger can rebuild the lab from the docs alone; no secret, personal data or private
address in the public tree; every security trade-off is stated openly; every claim in the docs is checked by a test.

## Repository map

| Path | What lives there |
|---|---|
| `scripts/lab.sh` | the only entry point: `up`, `down`, `rebuild`, `status`, `acceptance`, `export`, `init`, `secrets`, `customize`, `repo-egress`, `sync-host`, `replica`, `alert`, `restore-drill`, `budget`, `preflight`, `ca-rotation`, `purge`, `tools` (control-PC toolchain: `scripts/install-tools.sh`, `ci/control-tools.env`, `tests/install-tools-tests.sh`), `kit` (emergency kit: `scripts/emergency-kit.sh`, `tests/kit-tests.sh`, `docs/how-to/notfall-neuaufbau.md`) |
| `scripts/` | helpers behind `lab.sh` (`lab-*.py`), `ci-lint.sh`, `ci-tests.sh`, `consistency-check.py`, `gitleaks-local.sh` |
| `infra/` | OpenTofu: `infra/envs/local` (values and wiring), `infra/modules/libvirt-vm`, `infra/modules/cloud-init` (shared first-boot config); other environments live in `infra/envs/<name>/` and only override values (ADR-0027) |
| `ansible/` | playbooks (`ansible/site.yml`, `ansible/argocd.yml`, `backup-*.yml`, `verify-*.yml`), `ansible/roles`, `ansible/inventory` |
| `gitops/` | everything Argo CD reads from Git: `gitops/apps`, `gitops/platform`, `gitops/workloads`, `gitops/charts/notes-site`, `gitops/charts/matrix`, `gitops/charts/keycloak` |
| `secrets/` | SOPS-encrypted secrets per namespace (templates `*.sops.yaml.example`), KSOPS generators |
| `tests/` | offline suites `tests/<name>-tests.sh` (plain bash, one `OK`/`FAIL` line per check) |
| `docs/` | the German documentation, built with Zensical (`zensical.toml`, `docs/build.sh`) |
| `ci/` | pinned lint tool requirements (`ci/requirements-lint.txt`) |

Full map: `docs/reference/repository-layout.md` and `gitops/README.md`.

## Commands (all offline unless noted; no cluster, VM or secret needed)

```bash
bash scripts/ci-tests.sh                 # every tests/*-tests.sh, one after another
bash scripts/ci-tests.sh pins egress     # selected suites (name = file name without -tests.sh)
bash tests/agents-tests.sh               # one suite directly
bash scripts/ci-lint.sh                  # yamllint, shellcheck, ansible-lint (also: yaml | shell | ansible)
bash scripts/gitleaks-local.sh --staged  # secret scan of staged changes (needs podman or docker)
bash docs/build.sh /tmp/docs-site        # strict docs build, target empty or absent (needs network on first run)
bash scripts/lab.sh help                 # list of subcommands and options
```

- Tools. Required: `bash`, `git`, `python3` with PyYAML, and for lint `yamllint`, `shellcheck`, `ansible-lint`
  (pinned in `ci/requirements-lint.txt`; with one missing, `ci-lint.sh` prints `SKIP` and exits 2: an
  incomplete run, not green). Optional (the suite prints `SKIP`): `helm`, `ansible-playbook`, `sops`, `age`,
  `openssl`, `gitleaks`, `sudo -n`, `celpy`. A `SKIP` is not proof: say which checks you could not run.
- `gitleaks` must be 8.19 or newer; the apt package (8.16) is too old and its checks print `SKIP`.
  `bash scripts/security-scan.sh` runs all security and privacy checks, the same script as CI and pre-commit (tools:
  `bash scripts/install-security-tools.sh`; details: `docs/how-to/security-scan.md`). Never put a real name or domain into the repo to pass a check.
- Run test suites one at a time, never in parallel: they share `~/.cache/lab-sh-tests`, and
  `tests/firewall-netns-tests.sh` needs `sudo -n` (it prints `SKIP` without it).
- `scripts/lab.sh up|down|rebuild|purge|export|init|restore-drill|ca-rotation`, `replica install`,
  `alert install` and `acceptance` change the operator's host or a running VM. Do not run them unless the
  user asked for exactly that. `status`, `preflight`, `secrets` and `customize|repo-egress --dry-run` only read.

## Conventions

- **Language.** Code, identifiers, comments, script output, file names, commit messages: English.
  Everything under `docs/` and the Markdown manuals: German, Swiss spelling (de-CH, no sharp s, write
  "ss"). This file and `CONTRIBUTING.md` are English. `tests/language-tests.sh` enforces the split.
- **One place per value.** Never copy a value; add a check where a copy is unavoidable. The sources:
  - lab values (domain, IPs, sizes, repo URL): `infra/envs/local/lab.yaml`, overridden by the git-ignored
    `lab.local.yaml` beside it; read by OpenTofu, Ansible (`ansible/inventory/group_vars/all/lab.yml`) and `lab.sh`
  - shared image pins: `ansible/inventory/group_vars/all/images.yml`; Argo CD and KSOPS pins: `ansible/inventory/group_vars/all/argocd.yml`
  - list of all secrets: `ansible/inventory/group_vars/all/secrets.yml`
  - egress probe and rules, replica, alerts, restore drill: `egress.yml`, `backup_replica.yml`, `alert.yml`,
    `restore_drill.yml` in the same `ansible/inventory/group_vars/all/` folder
  - lint tools: `ci/requirements-lint.txt`; Ansible collections: `ansible/requirements.yml`; docs tools: `docs/build.sh`
  - copies Argo CD needs inside `gitops/` are written by `lab.sh customize` and `lab.sh repo-egress` and
    compared by `scripts/consistency-check.py` (`ansible/verify-consistency.yml`)
  - `docs/reference/versions.md` mirrors the pins for humans; `tests/pins-tests.sh` fails on drift
- **Pins.** Images by digest, tools by exact version, Python packages with hashes. No `latest`, no `curl | sh`.
- **Scripts** start with `#!/usr/bin/env bash` and `set -u` or stricter, never prompt in CI paths, are
  idempotent (existing and equal: `SKIP`; existing but different: abort, never overwrite) and shellcheck-clean.
  Ansible: fully qualified module names, idempotent tasks.
- **Edits** to existing files are exact old/new blocks: the old block must occur exactly once. No blind
  whole-file rewrites, no unrelated reformatting.
- **Commits.** Only when asked. English message via `git commit -F -` (heredoc): imperative subject, body says why.
  Never tag, never force-push. Push the main branch only after the user allowed it and `bash scripts/ci-tests.sh`
  plus `bash scripts/ci-lint.sh` are green. Run both before the commit. A `FAIL` blocks it; a `SKIP` does not.
  Do not push while Actions for that branch is still going. A red run: the next push is the fix, after it
  finished, and that push is done only when its Actions run is green.
- **Docs** use the Zensical features enabled in `zensical.toml`: admonitions (`!!! warning "Title"`), tabs,
  tables, abbreviations from `docs/_includes/abbreviations.md`. A new page goes into `nav` in `zensical.toml`.
  Mermaid diagrams are vertical only (`flowchart TD` or `TB`), with short labels, no wide `LR` graphs.

## Security hard rules

- Never commit a secret. Only SOPS-encrypted `secrets/**/*.sops.yaml` and `*.example` templates are allowed.
- Never print, log or paste a secret value (keys, tokens, passwords, kubeconfigs). Show paths and names only.
- The age private key stays on the operator machine (`~/.config/sops/age/keys.txt`). It never goes into
  Git, a GitHub repository, an issue, a log or a prompt.
- Do not weaken the safety prompts of destructive commands: `down` and `rebuild` ask `[y/N]` (`--yes` skips
  only that), `purge`, `restore-drill` and `rebuild --restore` always ask twice, `ca-rotation` asks. Never add a bypass flag.
- NetworkPolicy: default-deny for ingress and egress in every workload namespace; allow only named sources
  and targets (example `gitops/workloads/gitea/manifests/networkpolicy.yaml`; checks `tests/egress-tests.sh`, `ansible/verify-egress.yml`).
- The Argo CD UI is reachable only on the admin entrypoint (port 8444, admin networks only):
  `gitops/workloads/argocd/ingressroute.yaml` must list `admin` and nothing else.
- A deliberate security trade-off is documented as a `!!! warning` box in the page that introduces it
  (example: `docs/how-to/backup-replica.md`). Do not hide a limit; state it.

## Live-run pitfalls

- Preflight in `scripts/lab.sh` requires the current branch to be `main` and the tip to match the remote main tip. Do not weaken it and do not add a bypass. `up` and `rebuild` cannot succeed on a feature branch. A direct `ansible-playbook` of `ansible/verify-matrix.yml` is not `bash scripts/lab.sh acceptance`. Preflight also checks source trust (`scripts/lab-trust.sh`, ADR 0023): an SSH-signed descendant of `~/.config/k8s-lab/trusted-head`; the only bypass is the typed `--trust-override`. During `up`/`rebuild` Argo CD is pinned to the verified SHA (`scripts/pin-revision.py`; `gitops/apps/kustomization.yaml` must list every app file); `trust release` lifts it.
- `kubernetes.core.k8s_exec` takes one `command` string and splits it. A YAML list makes the module parse the API error as an exit code (`ansible/verify-matrix.yml`).
- `from_yaml` reads one document. A Deployment and its Service are two files (`gitops/workloads/matrix/manifests/service-synapse.yaml`). `deny-admin-api` (`gitops/workloads/matrix/manifests/middleware.yaml`) allows only the TEST-NET address 192.0.2.1, never routed. Never use a loopback address: a `kubectl port-forward` into Traefik would pass. A killed import leaves its `psql` in the helper pod; `lab.sh matrix-import recover` closes it (`docs/how-to/matrix-import.md`).
- The ansible-lint production profile (`ansible/.ansible-lint`) rejects lines over 160. yamllint allows 200 (`scripts/ci-lint.sh`). Fold long playbook lines.
- For a new namespace under `secrets/`, the legacy checksum in `tests/lab-sh-tests.sh` excludes only `*.sops.yaml`. Examples and `kustomization.yaml` stay in both sums.
- A new namespace is allowed only after `ansible/argocd.yml` applies `argocd_project_namespaces` from `ansible/inventory/group_vars/all/argocd.yml`.
- Read the `EXIT:` line in a log. A trailing `echo` makes the shell exit 0.
- `rebuild` empties the CNPG bucket (`docs/how-to/rebuild.md`). It is a clean start, not a restore. `down` keeps both backup buckets. `purge` deletes them. A full bucket after the VM is gone is `rebuild --restore` (`docs/concepts/decisions/0018-recover-from-backup.md`).
- Sudo is a terminal prompt. `sudo -n` is often missing. Never print or commit the password. A file outside the repo may feed the existing prompt. `restore-drill` and `purge` still ask twice.

## Definition of done

1. `bash scripts/ci-tests.sh` is green (a `SKIP` for an optional tool is fine, a `FAIL` is not).
2. `bash scripts/ci-lint.sh` is green with all three required tools installed.
4. Docs are updated in German, including `docs/reference/secrets-map.md` when a secret is added or changed
   and a new ADR in `docs/concepts/decisions/` (list in `index.md`, entry in `zensical.toml`) for a design decision.
5. A change that affects a running lab is proven with `bash scripts/lab.sh acceptance` by the operator
   (checks: `docs/reference/acceptance-checks.md`); say so in the change description if you could not run it.
6. After a push, Actions for that commit is green (`.github/workflows/lint.yml`, `.github/workflows/gitleaks.yml`). A red or unfinished run blocks the next push.

## Where to read more

- `docs/concepts/architecture.md`, `docs/concepts/security-model.md`, `docs/concepts/secret-flow.md`,
  `docs/concepts/network-edge.md`, `docs/concepts/backup-and-restore.md`
- ADRs: `docs/concepts/decisions/index.md` (for example `docs/concepts/decisions/0001-one-source-lab-yaml.md`,
  `docs/concepts/decisions/0004-sops-age-ksops.md`)
- `docs/reference/lab-sh.md`, `docs/reference/configuration.md`, `docs/reference/secrets-map.md`
- `docs/how-to/ci-lint.md`, `docs/how-to/secret-scan.md`, `docs/how-to/matrix.md`, `docs/tutorials/lab-for-friends.md`
- `CONTRIBUTING.md` (public copy), `SECURITY.md` (public copy)
