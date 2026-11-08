# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The project does
not use version numbers yet: the units of delivery are called **waves** (German: «Welle»), each one
a reviewed, tested and committed set of changes. A switch to semantic versioning with Git tags is
planned for the first public release; until then the headings below carry the wave name and date.
Dates are the commit dates of the working repository.

## [Unreleased]

### Added

- Export overlay for the public copy: `LICENSE` (GNU AGPL v3.0, full text), `SECURITY.md`,
  `CONTRIBUTING.md`, this changelog, and `# SPDX-License-Identifier: AGPL-3.0-only` headers in the
  scripts (`scripts/public/export.conf` is the one place for repository URL, edit path and SPDX values).
- `scripts/ci-tests.sh`: runs every offline test suite in `tests/`; the CI workflow `lint.yml` now runs
  it after `scripts/ci-lint.sh` (no cluster, no secrets).
- Mermaid is served from the docs site itself (pinned version, hash-checked tarball, subresource
  integrity attribute); no script comes from a CDN any more. A `Content-Security-Policy-Report-Only`
  header on the docs site lists the allowed sources.
- Pod Security Admission probes (an insecure pod spec is rejected by the API server) in
  `verify-cnpg.yml`, `verify-ksops.yml`, `verify-public.yml` and the notes-site check.
- Preflight checks for `sops`, `age`, `podman` and `ufw`, and an optional hint for the `argocd` CLI.
- `lab.sh gitea-import`: restores a `gitea dump` of another forge into the lab Gitea (users, organisations,
  repositories with wiki and LFS; no webhooks, templates or tokens). Idempotent (same dump: SKIP, foreign
  content: ABORT unless `--replace`), with an acceptance check. `scripts/gitea-import-vps-dump.sh` makes the
  encrypted dump on the source host, read-only. See ADR 0015 and `docs/how-to/gitea-import.md`.
- LFS is served by the lab Gitea (`LFS_START_SERVER: true`).
- `lab.sh` takes the Ansible inventory host from `LAB_INVENTORY_HOST` (default group `backup_host`).
- Backup replica (`lab.sh replica`, `scripts/lab-replica.py`): the backup buckets are mirrored with rsync over SSH to a
  second machine (rootless there, dedicated key limited by `rrsync -no-del`, `restrict` and `from=`), with a systemd user
  timer, freshness and checksum verification, and a documented trust boundary.
- `lab.sh restore-drill`: restores Gitea from the backups alone into a throwaway namespace, measured, behind a double
  confirmation and a fresh export.
- Alerts (`lab.sh alert`, `scripts/lab-alert.py`): checks for the last CNPG and K8up backup, the replica, rustfs and the
  edge, a pluggable sink interface (Matrix stays off: registration is closed and no bot token is created; desktop
  notification and journal as fallback), and `verify-alerts.yml`. Acceptance phases 16 and 17 are optional and report
  SKIP while not installed.
- Matrix in the lab (Synapse and Element Web): federation hard off, `server_name` from `matrix_server_name` in
  `lab.yaml` only, optional signing key (generated on first start and backed up when absent), idempotent admin,
  registration off, CNPG database backup and K8up backup of the media store and signing key, acceptance phase 18
  (`verify-matrix.yml`) and a restore drill after Gitea. See ADR 0016 and `docs/how-to/matrix.md`.
- `AGENTS.md` (the rules for contributors and AI coding agents: repository map, commands, conventions, security rules,
  definition of done) and a thin `CLAUDE.md` that points to it; `tests/agents-tests.sh` fails when a path, `lab.sh`
  subcommand or test suite named there no longer exists.

### Changed

- `zensical.toml`: `repo_url` and `edit_uri` (edit button on every docs page).
- The firewall drop-in `10-k3s-sicher.conf` is now `10-k3s-safe.conf`; the role removes the old file once.
- Ansible tasks whose result is inspected use `ignore_errors: true` instead of `failed_when: false`
  (ansible-core 2.19+ resets `msg` otherwise); optional fields in `fail_msg` use `default()`.
- The build script of the docs no longer mentions the private knowledge-graph plugin in the public copy.

## [Wave 3b] - 2026-10-31

### Changed

- Code, scripts, comments, messages, test names, `lab.sh` subcommands and options, Ansible task names and
  file names are English. Documentation stays German (Swiss spelling). Old German command names keep
  working as deprecated aliases for now. 21 files were renamed.

### Added

- `tests/language-tests.sh`: fails on German words in code and file names, the eszett character in the docs and Mermaid
  diagrams that are not top-down.

## [Wave 3] - 2026-10-31

### Added

- Pins and drift checks (issue 10): the probe image is defined once; Traefik, python, whoami and
  static-web-server are pinned by digest; `scripts/consistency-check.py` and `verify-consistency.yml`
  compare the copies in `gitops/` with `lab.yaml` and the group variables; `scripts/pins-online.py`
  checks pins against the registry.
- `scripts/ci-lint.sh` (yamllint, shellcheck, ansible-lint with hash-pinned tools) and the workflow `lint.yml`.
- Memory budget (issue 9): limits of all workloads fit into the RAM of the VM, with a test and a table in the docs.
- Acceptance phase 14 «consistency».

## [Wave 2] - 2026-10-30

### Added

- GitOps trust boundary and signed commits (issue 6): signature check as CI workflow, signing setup script.
- Break-glass age key, offline only (issue 11), with tests for the recovery path.
- Egress rules in the data namespaces (issue 5): default-deny with named exceptions and a probe in the verify playbooks.

### Changed

- Documentation fixes after the wave: break-glass key in the secrets map, `argocd` CLI in the prerequisites.

## [Wave 1] - 2026-10-30

### Added

- Network edge profile (`edge`) from one source, NodePorts closed from outside, ingress 80/443 stays (issues 1 and 2).
- Lab CA with `nameConstraints` (issue 7); a public certificate as a profile.

### Fixed

- `verify-certmanager.yml` runs on ansible-core 2.19+; the KSOPS check accepts empty placeholder values and ignores
  `.sops.yaml` templates; the admin port 8444 is open in the Traefik network policy.

## Before the waves - 2026-10-25 to 2026-10-30

### Added

- Stages 1 to 8c: k3s VM with libvirt and OpenTofu, hardening and audit rules, Argo CD (GitOps), Traefik,
  cert-manager, SOPS with age and KSOPS, CloudNativePG with backup to an S3 target, K8up file backup,
  Gitea on CNPG, notebook sites from one list, a secret scan as CI workflow.
- `scripts/lab.sh` (`up`, `down`, `rebuild`, `purge`, `acceptance`, `export`), the acceptance run, a documentation
  site (Zensical, Diátaxis) and the export tool that produces this public copy.
