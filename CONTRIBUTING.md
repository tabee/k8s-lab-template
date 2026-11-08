# Contributing

Thanks for your interest in k8s-lab. This is a learning project run by one maintainer, so please
keep changes small and explain why. Questions and ideas are welcome as issues; security problems
go to the private channel in [SECURITY.md](SECURITY.md), not into an issue.

## How changes get in

This repository is published from a private working repository. A pull request here is reviewed
as usual; accepted changes are applied in the working repository and appear here with the next
publication, and the pull request is then closed with a reference to that commit.

## Before you open a pull request

Run the two checks. Neither needs a cluster, a VM or a secret:

```bash
bash scripts/ci-lint.sh     # yamllint, shellcheck, ansible-lint (tools: pip install --require-hashes -r ci/requirements-lint.txt)
bash scripts/ci-tests.sh    # all offline test suites in tests/; a suite whose tool is missing prints SKIP
```

The same two commands run in GitHub Actions (`.github/workflows/lint.yml`). A pull request is
only ready when both are green.

The short rule set for contributors and AI coding agents (repository map, commands, conventions,
security rules, definition of done) is [AGENTS.md](AGENTS.md). `tests/agents-tests.sh` keeps it true.

## Rules of the repository

- **Language.** Code, comments, variable names, file names and commit messages: English.
  Documentation under `docs/`: German in the Swiss spelling (no eszett, «ss» instead). Issues and pull
  request texts can be English or German. `tests/language-tests.sh` checks this.
- **One place per value.** A version, an address or a limit is defined once; every other place reads
  it. `tests/consistency-tests.sh` and `tests/pins-tests.sh` fail when copies drift.
- **Pins.** Images by digest, tools by exact version, Python packages with hashes. No `latest`, no
  unpinned `curl | sh`.
- **No real secrets.** Only `secrets/*/*.sops.yaml.example` templates are committed. Never put
  keys, tokens, passwords, domains or addresses of your own network into a change.
- **Scripts run without prompts** (CI and automation have no terminal), are safe to run twice, and
  start with `#!/usr/bin/env bash` and `set -u` or stricter. New scripts need shellcheck-clean code.
- **Ansible.** Tasks use fully qualified module names and are idempotent. Use `ignore_errors: true`
  (not `failed_when: false`) when a later task reads `.msg` or `.failed` of the result, and
  `| default(...)` for optional fields in messages.
- **Diagrams.** Mermaid, top-down only (`flowchart TD` or `TB`).
- **Tests.** A behaviour change comes with a check in `tests/` (the suites are plain bash and
  print `OK` or `FAIL` per check).

## Licence of contributions

The project is licensed under the GNU Affero General Public License v3.0 only
([LICENSE](LICENSE)). By submitting a contribution you agree that it is licensed under the same
terms. New scripts carry the line `# SPDX-License-Identifier: AGPL-3.0-only` (the export adds it
to the usual script folders; you may add it yourself).

## Hinweis auf Deutsch

Kleine, begründete Änderungen sind willkommen. Vor dem Pull Request laufen lassen:
`bash scripts/ci-lint.sh` und `bash scripts/ci-tests.sh` (die Kurzregeln stehen in [AGENTS.md](AGENTS.md)). Doku auf Deutsch (Schweizer
Schreibweise, «ss» statt Eszett), Code und Kommentare auf Englisch. Das Repository wird aus einem privaten
Arbeits-Repository veröffentlicht: Übernommene Änderungen erscheinen mit der nächsten
Veröffentlichung.
