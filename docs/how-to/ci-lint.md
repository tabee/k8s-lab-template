---
title: CI-Prüfung
---

# CI-Prüfung: Lint und Pins ohne Cluster

**Ziel:** vor dem Push wissen, ob YAML, Shell-Skripte und Ansible sauber sind, und prüfen, dass die Pins noch stimmen.
Nichts davon braucht die VM.

## Alle Lint-Regeln an einer Stelle

```bash
bash scripts/ci-lint.sh            # yamllint, shellcheck, ansible-lint
bash scripts/ci-lint.sh yaml       # nur yamllint
bash scripts/ci-lint.sh shell      # nur shellcheck
bash scripts/ci-lint.sh ansible    # nur ansible-lint
```

Exit 0 = grün, 1 = mindestens eine Prüfung rot, 2 = ein Werkzeug fehlt. `scripts/ci-lint.sh` ist die **einzige Stelle**
der Regeln: Der Workflow `.github/workflows/lint.yml` und die lokalen Läufer rufen dieses Skript auf, damit lokal und in
der CI dasselbe gilt.

Fehlt ein Werkzeug (yamllint, shellcheck, ansible-lint), ist das ein `SKIP` mit Installationshinweis, nie ein rotes Ergebnis:
`ci-lint.sh all` führt die vorhandenen Werkzeuge aus, meldet `SKIP <Werkzeug>` für die anderen und endet mit 2, wenn nichts rot war.
Rot gewinnt immer (Exit 1). Ein einzelner Modus (`yaml`, `shell`, `ansible`) ohne sein Werkzeug endet mit 2.

| Prüfung | Was | Regeln |
|---|---|---|
| `yamllint` | alle `*.yml` und `*.yaml` ausser den Helm-Templates (die prüft `helm template`) | Profil `relaxed`, Zeilen bis 200 Zeichen |
| `shellcheck` | `scripts/*.sh`, `ansible/scripts/*.sh`, `tests/*.sh` | ab Stufe `warning` |
| `ansible-lint` | `ansible/` | Konfiguration `ansible/.ansible-lint` |

Die Werkzeug-Versionen stehen in `ci/requirements-lint.txt` und werden mit `pip install --require-hashes` installiert.
Die Ansible-Collections stehen mit exakter Version in `ansible/requirements.yml`.

!!! note "Was die CI nicht prüft"
    Die CI braucht keinen Cluster und führt deshalb die `verify-*.yml` **nicht** aus. Diese laufen auf der VM
    (`bash scripts/lab.sh acceptance`). Die Testsuiten unter `tests/` laufen dagegen **auch in der CI**, soweit sie
    ohne Cluster, ohne Geheimnisse und ohne Spezialwerkzeuge auskommen (siehe nächster Abschnitt).

## Die Testsuiten in der CI

Der letzte Schritt des Workflows ist `bash scripts/ci-tests.sh`. Das Skript startet alle `tests/*-tests.sh`
nacheinander (sie teilen sich einen Cache, darum nie parallel), druckt je Suite eine Zeile `ok=… fail=… skip=… Ns`
und endet mit Exit 0 (alles grün), 1 (eine Suite rot: Exit ungleich 0 oder eine Zeile `FAIL `) oder 2 (falscher
Aufruf oder unbekannte Suite). Lokal: `bash scripts/ci-tests.sh` für alle, `bash scripts/ci-tests.sh pins language`
für einzelne. Fehlt einer Suite ein Werkzeug (`sops`, `age`, `helm`, `nft`, `gitleaks` …), meldet sie `SKIP` statt
Fehler; im CI-Image sind deshalb nur die Werkzeuge aus `ci/requirements-lint.txt` da. Der Schritt läuft mit
`if: always()`, damit ein roter Lint-Lauf die Testergebnisse nicht verdeckt. Die Suiten brauchen nur den
Checkout: kein Git-Benutzer, keine Zugangsdaten.

## Der Workflow

`.github/workflows/lint.yml` läuft bei jedem Push, jedem Pull-Request und von Hand. Er nutzt dasselbe `python`-Image wie
die Egress-Proben (per Digest gepinnt; `tests/pins-tests.sh` wird rot, wenn die beiden auseinanderlaufen), holt das
Repository mit `git` (das Image hat kein Node.js, daher kein `actions/checkout`) und installiert die Werkzeuge mit
Hashprüfung.

!!! warning "Der Workflow braucht einen Runner"
    Ohne einen Gitea-Actions-Runner läuft er nirgends. Der Runner ist nicht Teil dieses Repositorys; bis es einen gibt,
    ist `bash scripts/ci-lint.sh` lokal der Nachweis.

In der öffentlichen Fassung heisst derselbe Workflow `.github/workflows/lint.yml` (Pfadregel in
`scripts/public/replacements.tsv`).

## Pins prüfen

```bash
python3 scripts/pins-online.py --check            # Format offline, danach gegen die Registries
python3 scripts/pins-online.py --check --offline  # nur Format und Traefik-Paar, ohne Netz
```

Liest jeden Digest-Pin des Repositorys (Format `Tag@sha256:<64 Hex-Zeichen>`) und prüft, dass bei Traefik Digest und
`versionOverride` zusammenpassen. Online fragt es zusätzlich jede Registry: existiert der Digest noch (sonst Fehler,
Exit 1)? Zeigt der Tag noch auf diesen Digest (sonst `INFO`: der Tag wurde neu hochgeladen; der Pin läuft mit dem alten
Image weiter, ein Anheben ist deine Entscheidung)? Entspricht die `appVersion` des Traefik-Charts dem
`versionOverride` (braucht `helm`)? Das Netz ist nötig, deshalb gehört der Online-Teil **nicht** zur Abnahme; die
Testsuite `tests/pins-tests.sh` braucht kein Netz. Der Pin der Prüf-Pods steht nur in
`ansible/inventory/group_vars/all/images.yml`.

## Kopien vergleichen

`ansible-playbook ansible/verify-consistency.yml` (Phase 14 der Abnahme) vergleicht Werte, die an zwei Stellen stehen
müssen, weil Argo CD nur Git liest: Gateway, Repo-CIDRs und -Port, S3-Port, Domain, Image-Pins und Branch. Die Logik
steht in `scripts/consistency-check.py`; die Tests dazu in `tests/consistency-tests.sh`. Rot heisst: eine Kopie ist
veraltet. Abhilfe: `bash scripts/lab.sh customize` oder `bash scripts/lab.sh repo-egress`, dann committen.

## Siehe auch

- [Versionen und Pins](../reference/versions.md)
- [Abnahme-Prüfungen](../reference/acceptance-checks.md#phase-14)
- [Secret-Scan](secret-scan.md): die zweite Prüfung der CI
