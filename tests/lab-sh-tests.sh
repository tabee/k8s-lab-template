#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# CLI, configuration and lifecycle tests for scripts/lab.sh; no live tools or cluster.
# Usage: bash tests/lab-sh-tests.sh [repo root]
# shellcheck disable=SC2016
set -u
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
fail=0
n=0
# shellcheck source=tests/helpers/lab-sh-sandbox.sh
source "$R/tests/helpers/lab-sh-sandbox.sh"

echo "== Basics"
lab > /dev/null < /dev/null; ok "no command: exit 2" "$?" 2
lab help < /dev/null; ok "help: Exit 0" "$?" 0
has "help lists rebuild" "rebuild" "$T/out"
has "help lists the source command" "lab.sh source ACTION" "$T/out"
lab nonsense < /dev/null; ok "unknown command: exit 2" "$?" 2
lab status --broken < /dev/null; ok "unknown option: exit 1" "$?" 1
vm absent; : > "$S/rustfs_up"; fresh
lab status < /dev/null; ok "status without VM: exit 0" "$?" 0
has "status reports missing" "VM k3s-lab (192.168.122.50): missing" "$T/out"
echo "vm_nmae: x" >> "$T/repo/infra/envs/local/lab.local.yaml"
lab status < /dev/null; ok "typo in the override: exit 1" "$?" 1
has "message Unknown key" "Unknown key 'vm_nmae'" "$T/out"
sed -i '/^vm_nmae:/d' "$T/repo/infra/envs/local/lab.local.yaml"
echo "vm_name:" >> "$T/repo/infra/envs/local/lab.local.yaml"
lab status < /dev/null; ok "empty key: exit 1" "$?" 1
has "empty key names vm_name" "'vm_name'" "$T/out"
sed -i '/^vm_name:$/d' "$T/repo/infra/envs/local/lab.local.yaml"

echo "== Preflight"
lab preflight < /dev/null; ok "preflight ok: Exit 0" "$?" 0
has "preflight: 0 errors" "0 errors" "$T/out"
has "preflight: source trust is off for a private Git server" "Source trust check is off" "$T/out"
has "preflight: VM memory equals the prod profile" "= prod profile" "$T/out"
echo "memory_mib: 10240" >> "$T/repo/infra/envs/local/lab.local.yaml"
lab preflight < /dev/null; ok "preflight with a bigger lab VM: still exit 0 (warning only)" "$?" 0
has "preflight warns about the memory drift" "differs from the prod profile (8192 MiB)" "$T/out"
sed -i '/^memory_mib:/d' "$T/repo/infra/envs/local/lab.local.yaml"
lab preflight < /dev/null; ok "preflight ok again: Exit 0" "$?" 0
for w in sops age podman ufw; do has "preflight checks the tool $w" "ok      Tool $w" "$T/out"; done
has "preflight: argocd is only a hint" "hint    optional tool 'argocd'" "$T/out"
hasnt "preflight: the missing argocd CLI is no error" "ERROR  Tool 'argocd'" "$T/out"
LAB_TOOLS_EXTRA=no-such-tool-xyz lab preflight < /dev/null; ok "a missing extra tool: exit 1" "$?" 1
has "message names the missing tool" "Tool 'no-such-tool-xyz' is missing" "$T/out"
has "the other checks still run" "Branch main" "$T/out"
echo "== Inventory host (one place)"
fresh
lab preflight < /dev/null; ok "preflight: exit 0" "$?" 0
has "values are read for the inventory group backup_host" "ansible backup_host -m ansible.builtin.debug" "$S/calls"
fresh
LAB_INVENTORY_HOST=other-box lab preflight < /dev/null; ok "LAB_INVENTORY_HOST: exit 0" "$?" 0
has "LAB_INVENTORY_HOST reaches ansible" "ansible other-box -m ansible.builtin.debug" "$S/calls"
hasnt "the default no longer reaches ansible" "ansible backup_host" "$S/calls"
ok "lab.sh holds no host name of the owner" "$(grep -c 'steuerrechner' "$R/scripts/lab.sh")" 0
ok "the inventory group name is the default in one place" "$(grep -c ':-backup_host}' "$R/scripts/lab.sh")" 1
mv "$H/age.txt" "$H/age.alt"
lab preflight < /dev/null; ok "age key missing: exit 1" "$?" 1
has "message age key" "age key is missing" "$T/out"
has "other checks still run" "Branch main" "$T/out"
mv "$H/age.alt" "$H/age.txt"
sed -i 's#http://192.168.122.1:#http://10.9.9.1:#' "$T/repo/gitops/workloads/db-lab/objectstore.yaml"
lab preflight < /dev/null; ok "wrong gateway in gitops: exit 1" "$?" 1
has "message other network" "bash scripts/lab.sh customize" "$T/out"
cp "$R/gitops/workloads/db-lab/objectstore.yaml" "$T/repo/gitops/workloads/db-lab/objectstore.yaml"
lab preflight < /dev/null; ok "preflight ok again: exit 0" "$?" 0
has "state matches lab.yaml" "gitops/ matches lab.yaml" "$T/out"
cp "$T/repo/infra/envs/local/lab.local.yaml" "$T/lab.local.yaml.bak"
printf 'repo_url: ssh://git@git.example.org/YOUR-NAME/k8s-lab.git\n' >> "$T/repo/infra/envs/local/lab.local.yaml"
lab preflight < /dev/null; ok "placeholder repo_url: exit 1" "$?" 1
has "message placeholder" "repo_url is still the placeholder" "$T/out"
cp "$T/lab.local.yaml.bak" "$T/repo/infra/envs/local/lab.local.yaml"

echo "== repo-egress: preflight and options (issue 5)"
lab preflight < /dev/null; ok "preflight: egress policies match lab.yaml: exit 0" "$?" 0
has "preflight reports the egress policies" "the git server address and port in the egress policies match" "$T/out"
sed -i 's/^repo_egress_cidrs:.*/repo_egress_cidrs: 192.0.2.99/' "$T/repo/infra/envs/local/lab.local.yaml"
lab preflight < /dev/null; ok "preflight: egress drift: exit 1" "$?" 1
has "preflight: drift message names the command" "bash scripts/lab.sh repo-egress" "$T/out"
lab repo-egress --dry-run < /dev/null; ok "repo-egress --dry-run: exit 0" "$?" 0
has "repo-egress --dry-run shows the change" "WOULD CHANGE" "$T/out"
lab preflight < /dev/null; ok "repo-egress --dry-run writes nothing: preflight still exit 1" "$?" 1
lab repo-egress < /dev/null; ok "repo-egress: exit 0" "$?" 0
has "repo-egress writes" "EDIT" "$T/out"
lab preflight < /dev/null; ok "preflight after repo-egress: exit 0" "$?" 0
lab repo-egress < /dev/null; ok "repo-egress again: exit 0" "$?" 0
has "repo-egress again: SKIP" "SKIP" "$T/out"
hasnot "repo-egress again: no EDIT" "EDIT" "$T/out"
sed -i 's/^repo_egress_cidrs:.*/repo_egress_cidrs: 203.0.113.10/' "$T/repo/infra/envs/local/lab.local.yaml"
lab preflight < /dev/null; ok "preflight: placeholder address: exit 1" "$?" 1
lab repo-egress < /dev/null; ok "repo-egress with the placeholder: exit 1" "$?" 1
has "repo-egress with the placeholder: ABORT" "ABORT" "$T/out"
sed -i 's/^repo_egress_cidrs:.*/repo_egress_cidrs: 192.0.2.7/' "$T/repo/infra/envs/local/lab.local.yaml"
lab repo-egress < /dev/null; ok "repo-egress back to the sandbox address: exit 0" "$?" 0
lab preflight < /dev/null; ok "preflight ok again: exit 0" "$?" 0
lab status --dry-run < /dev/null; ok "status --dry-run: exit 1" "$?" 1
has "message: flags only for repo-egress" "only applies to init, customize, ca-rotation and repo-egress" "$T/out"
lab repo-egress --resolve --dry-run < /dev/null; ok "--resolve with --dry-run: exit 1" "$?" 1
has "message: --resolve and --dry-run exclude each other" "exclude each other" "$T/out"
lab repo-egress extra < /dev/null; ok "repo-egress with a stray argument: exit 1" "$?" 1

echo "== customize: gitops/ from lab.yaml, once and idempotent"
GS0=$(cd "$T/repo" && git status --porcelain --untracked-files=all)
lab customize; ok "customize with the defaults: exit 0" "$?" 0
has "customize: nothing to do" "SKIP: gitops/ already matches" "$T/out"
ok "customize on the owner machine: repo unchanged" "$(cd "$T/repo" && git status --porcelain --untracked-files=all)" "$GS0"
printf 'domain: test.local\nrepo_url: ssh://git@git.lab-test.invalid/me/k8s-lab.git\ngateway: 192.168.123.1\nvm_cidr: 192.168.123.0/24\nvm_ip: 192.168.123.50\n' >> "$T/repo/infra/envs/local/lab.local.yaml"
lab customize --dry-run; ok "customize --dry-run: exit 0" "$?" 0
has "dry run names changes" "WOULD CHANGE: gitops/" "$T/out"
ok "dry run writes nothing" "$(cd "$T/repo" && git status --porcelain --untracked-files=all)" "$GS0"

echo "== deprecated German aliases: still work, note on stderr"
lab anpassen --trocken; ok "alias anpassen --trocken: exit 0" "$?" 0 # lang-allow: alias test
has "alias anpassen: note names the English command" "'anpassen' is deprecated, use 'customize'" "$T/out" # lang-allow: alias test
has "alias --trocken: note names the English option" "'--trocken' is deprecated, use '--dry-run'" "$T/out" # lang-allow: alias test
has "alias note names the removal date" "removed before December 2026" "$T/out"
has "alias anpassen --trocken behaves like customize --dry-run" "WOULD CHANGE: gitops/" "$T/out" # lang-allow: alias test
# the notes are printed before the command runs, so an unknown command shows the option notes without side effects
lab nonsense --ja --zerstoeren-ok --auch-image --neuer-age-schluessel --host-keys-holen --ohne-export --ersetzen < /dev/null # lang-allow: alias test
ok "legacy options on an unknown command: exit 1 (option check)" "$?" 1
for pair in "--ja:--yes" "--zerstoeren-ok:--destroy-ok" "--auch-image:--include-image" "--neuer-age-schluessel:--new-age-key" "--host-keys-holen:--fetch-host-keys" "--ohne-export:--no-export" "--ersetzen:--replace"; do # lang-allow: alias list
  # One legacy option exists only in the private lab.sh: the public export has no such alias (PRIVATE block)
  if [ "${pair%%:*}" = "--ersetzen" ] && ! grep -Fq -- "--ersetzen)" "$R/scripts/lab.sh"; then continue; fi # lang-allow: alias list
  has "alias note ${pair%%:*} -> ${pair##*:}" "'${pair%%:*}' is deprecated, use '${pair##*:}'" "$T/out"
done
for pair in "abnahme:acceptance" "geheimnisse:secrets" "oeffentlich:public" "waechter:guard"; do # lang-allow: alias list
  # Two legacy command names exist only in the private lab.sh; the public export does not carry them
  if ! grep -Fq -- "${pair%%:*})" "$R/scripts/lab.sh"; then continue; fi
  lab "${pair%%:*}" --broken < /dev/null
  has "alias note ${pair%%:*} -> ${pair##*:}" "'${pair%%:*}' is deprecated, use '${pair##*:}'" "$T/out"
done
lab customize --dry-run; has "the English name prints no note" "WOULD CHANGE: gitops/" "$T/out"
hasnot "the English name prints no deprecation note" "deprecated" "$T/out"
lab preflight < /dev/null; ok "preflight before customize: Exit 1" "$?" 1
lab customize; ok "customize with own values: exit 0" "$?" 0
has "customize writes" "EDIT: gitops/" "$T/out"
has "state file new" "EDIT: gitops/values-state.yaml" "$T/out"
OLDDOM=$(sed -n 's/^domain: //p' "$R/gitops/values-state.yaml")
# serverName is the Matrix identity. It does not follow a domain change (phase 2 sets the imported name).
(cd "$T/repo" && grep -rn -e "$OLDDOM" -e "192.168.122" gitops zensical.toml | grep -v "^gitops/sites.yaml\|clusterissuer\|networkpolicy\|values-gitea\|serverName:" > "$T/rest.txt"; true)
ok "no old domain or old network left in Argo files" "$(grep -c -e "$OLDDOM" -e "192.168.122" "$T/rest.txt")" 0
has "new domain in the state file" "domain: test.local" "$T/repo/gitops/values-state.yaml"
has "new network in traefik" "192.168.123.0/24" "$T/repo/gitops/platform/traefik/values.yaml"
has "new repo address in the application" "ssh://git@git.lab-test.invalid/me/k8s-lab.git" "$T/repo/gitops/apps/docs.yaml"
GS1=$(cd "$T/repo" && git status --porcelain --untracked-files=all | sha1sum)
lab customize; ok "customize second time: exit 0" "$?" 0
has "second time: SKIP" "SKIP: gitops/ already matches" "$T/out"
ok "second time: nothing changed" "$(cd "$T/repo" && git status --porcelain --untracked-files=all | sha1sum)" "$GS1"
(cd "$T/repo" && find gitops zensical.toml -type f | sort | xargs sha1sum | sha1sum > "$T/anp1.sum")
lab customize --yes; (cd "$T/repo" && find gitops zensical.toml -type f | sort | xargs sha1sum | sha1sum | diff -q - "$T/anp1.sum" > /dev/null); ok "content byte-identical after the second run" "$?" 0
printf '#!/usr/bin/env bash\necho "# scanned (stub)"\necho "git.lab-test.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest"\n' > "$T/bin/ssh-keyscan"; chmod +x "$T/bin/ssh-keyscan"
MODE_BEFORE=$(stat -c %a "$T/repo/infra/envs/local/lab.local.yaml")
lab customize --fetch-host-keys --yes; ok "fetch-host-keys: exit 0" "$?" 0
has "repo_known_hosts written" 'repo_known_hosts: ["git.lab-test.invalid ssh-ed25519' "$T/repo/infra/envs/local/lab.local.yaml"
ok "lab.local.yaml: mode as before" "$(stat -c %a "$T/repo/infra/envs/local/lab.local.yaml")" "$MODE_BEFORE"
lab customize --fetch-host-keys --yes; has "fetch-host-keys second time: SKIP" "SKIP: repo_known_hosts" "$T/out"
lab up --dry-run < /dev/null; ok "--dry-run only for init and customize" "$?" 1
lab customize --git-init; ok "--git-init only for public" "$?" 1
cp "$T/lab.local.yaml.bak" "$T/repo/infra/envs/local/lab.local.yaml"
(cd "$T/repo" && git checkout -q -- gitops zensical.toml)
lab customize; has "back on the defaults: SKIP" "SKIP: gitops/ already matches" "$T/out"

echo "== customize: separate private secrets repo (secrets_repo_url, ADR 0022)"
SREPO=$(sed -n 's/^repo_url: //p' "$T/repo/infra/envs/local/lab.yaml" | sed 's/k8s-lab\.git$/k8s-lab-secrets.git/')
printf 'secrets_repo_url: %s\n' "$SREPO" >> "$T/repo/infra/envs/local/lab.local.yaml"
lab customize --dry-run; ok "secrets repo --dry-run: exit 0" "$?" 0
has "secrets repo: dry run names a secrets app" "WOULD CHANGE: gitops/apps/secrets-matrix.yaml (secrets_repo_url" "$T/out"
lab customize; ok "secrets repo: customize exit 0" "$?" 0
has "secrets repo: secrets app points at the secrets repo" "repoURL: $SREPO" "$T/repo/gitops/apps/secrets-keycloak.yaml"
hasnt "secrets repo: other apps keep the code repo" "$SREPO" "$T/repo/gitops/apps/matrix.yaml"
has "secrets repo: state file has it" "secrets_repo_url: $SREPO" "$T/repo/gitops/values-state.yaml"
lab customize; has "secrets repo: second run SKIP" "SKIP: gitops/ already matches" "$T/out"
printf 'secrets_repo_url: ssh://git@other-host.invalid/me/s.git\n' >> "$T/repo/infra/envs/local/lab.local.yaml"
lab customize; ok "secrets repo on another host: exit 1" "$?" 1
has "secrets repo on another host: same host and port" "same host and port" "$T/out"
cp "$T/lab.local.yaml.bak" "$T/repo/infra/envs/local/lab.local.yaml"
(cd "$T/repo" && git checkout -q -- gitops)
lab customize; has "secrets repo back on the defaults: SKIP" "SKIP: gitops/ already matches" "$T/out"

echo "== secrets-repo: usage (the copy itself: tests/secrets-repo-tests.sh)"
lab secrets-repo < /dev/null; ok "secrets-repo without arguments: exit 1" "$?" 1
has "secrets-repo: usage" "secrets-repo export DIR" "$T/out"
lab secrets-repo sideways "$T/x" < /dev/null; ok "secrets-repo unknown verb: exit 1" "$?" 1
lab secrets-repo import "$T/x" --prune < /dev/null; ok "--prune with import: exit 1" "$?" 1
lab status --prune < /dev/null; ok "--prune only for secrets-repo: exit 1" "$?" 1
mkdir -p "$T/sr" && git -C "$T/sr" init -q
lab secrets-repo export "$T/sr" --dry-run < /dev/null; ok "secrets-repo export --dry-run: exit 0" "$?" 0
has "secrets-repo export --dry-run: WOULD COPY" "WOULD COPY" "$T/out"
ok "secrets-repo export --dry-run: writes nothing" "$(find "$T/sr" -path "$T/sr/.git" -prune -o -type f -print | wc -l)" 0

echo "== customize: ingress networks (edge_ingress_cidrs) as a block in Traefik"
printf 'edge_ingress_cidrs: 192.168.122.0/24,10.5.0.0/16\n' >> "$T/repo/infra/envs/local/lab.local.yaml"
lab preflight < /dev/null; ok "preflight: ingress networks differ from gitops/: exit 1" "$?" 1
has "message ingress networks" "edge_ingress_cidrs" "$T/out"
lab customize --dry-run; ok "customize --dry-run (ingress): exit 0" "$?" 0
has "dry run names the Traefik file" "WOULD CHANGE: gitops/platform/traefik/values.yaml (edge_ingress_cidrs)" "$T/out"
ok "dry run writes nothing (ingress)" "$(cd "$T/repo" && git status --porcelain --untracked-files=all)" "$GS0"
lab customize; ok "customize (ingress): exit 0" "$?" 0
has "Traefik: first network" "      - 192.168.122.0/24" "$T/repo/gitops/platform/traefik/values.yaml"
has "Traefik: second network" "      - 10.5.0.0/16" "$T/repo/gitops/platform/traefik/values.yaml"
has "state: ingress networks" "edge_ingress_cidrs: 192.168.122.0/24,10.5.0.0/16" "$T/repo/gitops/values-state.yaml"
GS2=$(cd "$T/repo" && git status --porcelain --untracked-files=all | sha1sum)
lab customize; ok "customize (ingress) second time: exit 0" "$?" 0
has "(ingress) second time: SKIP" "SKIP: gitops/ already matches" "$T/out"
ok "(ingress) second time: nothing changed" "$(cd "$T/repo" && git status --porcelain --untracked-files=all | sha1sum)" "$GS2"
cp "$T/lab.local.yaml.bak" "$T/repo/infra/envs/local/lab.local.yaml"
lab customize; ok "back to one network: exit 0" "$?" 0
ok "back: Traefik without the second network" "$(grep -c '10.5.0.0/16' "$T/repo/gitops/platform/traefik/values.yaml")" 0
ok "back: repo as at the start" "$(cd "$T/repo" && git status --porcelain --untracked-files=all)" "$GS0"

echo "== up: VM missing, bucket with old WAL"
vm absent; : > "$S/rustfs_up"; : > "$S/bucket_used"; fresh
lab up <<< "$SUDO"; ok "up refuses with old WAL" "$?" 1
has "Message Expected empty archive" "Expected empty archive" "$T/out"
hasnot "no tofu apply" "tofu apply" "$S/calls"
rm -f "$S/bucket_used"

echo "== up: image with a wrong checksum"
touch "$S/curl_bad"; rm -rf "$H/data/images"; fresh
lab up <<< "$SUDO"; ok "wrong SHA-256: exit 1" "$?" 1
has "message SHA-256" "SHA-256 of the image does not match" "$T/out"
hasnot "no tofu apply after a wrong image" "tofu apply" "$S/calls"
rm -f "$S/curl_bad"

echo "== up: fresh build"
vm absent; fresh
lab up <<< "$SUDO"; ok "up: Exit 0" "$?" 0
has "tofu apply lief" "tofu apply" "$S/calls"
has "backup-host.yml with password via stdin" "ansible-playbook backup-host.yml --become-password-file -" "$S/calls"
has "site.yml lief" "ansible-playbook site.yml" "$S/calls"
has "argocd.yml lief" "ansible-playbook argocd.yml" "$S/calls"
hasnot "up without source trust: Argo CD is not pinned" "argocd_pin_revision" "$S/calls"
hasnot "up without source trust: nothing to release" "argocd-release-pin.yml" "$S/calls"
has "Total changed=0" "Total changed=0" "$T/out"
has "public probe without acme_*: SKIP" "SKIP: public probe off" "$T/out"
hasnot "public.yml did not run" "public.yml" "$S/calls"
has "timing table with TOTAL" "TOTAL" "$T/out"
has "stopwatch per phase" "Build VM (tofu plan + apply)" "$T/out"
hasnot "password not in the call list" "s3kr1t" "$S/calls"
hasnot "password not in the log" "s3kr1t" "$T/out"
L=$(first "$H/data/logs" "lab-up-*.log")
ok "log file present" "$([ -n "$L" ] && echo yes || echo no)" yes
ok "log file mode 600" "$(stat -c %a "$L")" 600
has "alerts are paused while the playbooks run (issue #21)" "MARKER present site.yml" "$S/calls"
has "the marker names the command" '"command": "up"' "$S/marker.last"
ok "the marker is removed at the end of up" "$([ -e "$H/alert-maintenance.json" ] && echo present || echo gone)" gone
a=$(line "ansible-playbook backup-host.yml"); b=$(line "ansible-playbook site.yml"); c=$(line "ansible-playbook argocd.yml")
ok "order backup-host < site < argocd" "$([ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && echo yes || echo no)" yes

echo "== up: unavailable optional sites do not block core readiness"
printf 'app1 Synced/Healthy\ndocs Unknown/Unknown\nnotes-notes OutOfSync/Degraded\n' > "$S/apps"
fresh
lab up <<< "$SUDO"; ok "up with unavailable optional sites: exit 0" "$?" 0
has "up warns about optional sites" "WARNING: optional sites are not ready" "$T/out"
has "up reports unavailable docs" "docs Unknown/Unknown" "$T/out"
has "up reports degraded notes" "notes-notes OutOfSync/Degraded" "$T/out"
has "up completes core readiness" "All required applications Synced/Healthy" "$T/out"
hasnot "up does not time out on optional sites" "Still open after" "$T/out"
rm -f "$S/apps"

echo "== up: second run (VM running, nothing to do)"
fresh
lab up <<< "$SUDO"; ok "second up: exit 0" "$?" 0
has "second up: Total changed=0" "Total changed=0" "$T/out"
hasnot "second up destroys nothing" "destroy" "$S/calls"
has "plan names 0 new" "Plan: 0 new, 0 change, 0 destroy" "$T/out"
echo 2 > "$S/changed"; fresh
lab up <<< "$SUDO"; has "changed is counted" "Total changed=" "$T/out"
grep -Fq "Total changed=0" "$T/out"; ok "changed=2 per run is not swallowed" "$?" 1
rm -f "$S/changed"

echo "== up: plan would destroy"
echo '{"resource_changes":[{"address":"libvirt_domain.vm","change":{"actions":["delete","create"]}}]}' > "$S/plan.json"; fresh
lab up <<< "$SUDO"; ok "plan with replace: exit 1" "$?" 1
has "message ABORT" "ABORT" "$T/out"
hasnot "no apply" "apply" "$S/calls"
lab up --destroy-ok <<< "$SUDO"; ok "--destroy-ok: exit 0" "$?" 0
rm -f "$S/plan.json"

echo "== down and export (parachute)"
fresh
lab down --yes < /dev/null; ok "down without export: exit 1" "$?" 1
has "message export first" "Run 'bash scripts/lab.sh export' first" "$T/out"
ok "VM still running" "$(cat "$S/vm")" running
# Optional content sites must not hold the post-export readiness phase open.
printf 'app1 Synced/Healthy\ndocs Synced/Degraded\nnotes-notes Synced/Degraded\n' > "$S/apps"
lab export <<< "$SUDO"; ok "export: Exit 0" "$?" 0
has "export warns about optional degraded sites" "WARNING: optional sites are not ready" "$T/out"
has "export reports the degraded notes site" "notes-notes Synced/Degraded" "$T/out"
has "export finishes required readiness despite optional sites" "All required applications Synced/Healthy" "$T/out"
rm -f "$S/apps"
E=$(first "$H/data/vm-export" "k3s-lab-before-drill-*.qcow2")
ok "qcow2 da" "$([ -f "$E" ] && echo yes || echo no)" yes
ok "xml da" "$([ -f "${E%.qcow2}.xml" ] && echo yes || echo no)" yes
ok "sha256 present" "$([ -f "$E.sha256" ] && echo yes || echo no)" yes
ok "Export Modus 600" "$(stat -c %a "$E")" 600
ok "VM started again after the export" "$(cat "$S/vm")" running
has "export shut the VM down" "virsh shutdown k3s-lab" "$S/calls"
echo n | lab down; ok "down with no: exit 0" "$?" 0
has "abort reported" "Aborted" "$T/out"
ok "VM unchanged after No" "$(cat "$S/vm")" running
echo snap1 > "$S/snaps"
lab down --yes < /dev/null; ok "down --yes: Exit 0" "$?" 0
ok "VM weg" "$(cat "$S/vm")" absent
has "snapshots removed" "Snapshot metadata removed: snap1" "$T/out"
has "known_hosts cleaned up" "ssh-keygen -R 192.168.122.50" "$S/calls"
ok "kubeconfig removed" "$([ -f "$H/.kube/k3s-lab.kubeconfig" ] && echo no || echo yes)" yes
lab down < /dev/null; ok "down without VM: exit 0" "$?" 0
has "down without VM: nothing to do" "nothing to do" "$T/out"

echo "== rebuild (bucket with old WAL, rustfs running)"
vm running; : > "$S/rustfs_up"; : > "$S/bucket_used"; fresh
lab export <<< "$SUDO"
lab rebuild --yes <<< "$SUDO"; ok "rebuild: Exit 0" "$?" 0
a=$(line "lab-backups-empty.yml"); b=$(line " apply "); c=$(line "tofu.* destroy")
ok "order destroy < empty bucket < apply" "$([ -n "$a" ] && [ "$c" -lt "$a" ] && [ "$a" -lt "$b" ] && echo yes || echo no)" yes
has "scope cnpg only" "lab_empty_scope=cnpg" "$S/calls"
ok "bucket empty afterwards" "$([ -f "$S/bucket_used" ] && echo used || echo empty)" empty
ok "VM running again" "$(cat "$S/vm")" running

echo "== rebuild (rustfs not running yet)"
lab export <<< "$SUDO"
rm -f "$S/rustfs_up"; : > "$S/bucket_used"; fresh
lab rebuild --yes <<< "$SUDO"; ok "rebuild without rustfs: exit 0" "$?" 0
has "bucket rechecked" "Re-check the Postgres bucket" "$T/out"
ok "backup-host.yml twice" "$(grep -c 'ansible-playbook backup-host.yml' "$S/calls")" 2
ok "bucket empty afterwards" "$([ -f "$S/bucket_used" ] && echo used || echo empty)" empty

echo "== alert marker while the VM is rebuilt on purpose (issue #21)"
rm -f "$S/marker.last"; vm running; : > "$S/rustfs_up"; : > "$S/bucket_used"; fresh
lab export <<< "$SUDO"
lab rebuild --yes <<< "$SUDO"; ok "rebuild: exit 0" "$?" 0
has "rebuild: marker present while ansible ran" "MARKER present argocd.yml" "$S/calls"
has "rebuild: the marker names the command" '"command": "rebuild"' "$S/marker.last"
ok "rebuild: the marker carries the pid of lab.sh" "$(python3 -c "import json; print(type(json.load(open('$S/marker.last'))['pid']).__name__)")" int
ok "rebuild: marker removed" "$([ -e "$H/alert-maintenance.json" ] && echo present || echo gone)" gone
has "rebuild says that alerts are paused" "Alerts paused while lab.sh rebuild runs" "$T/out"
vm absent; fresh; : > "$S/fail_site.yml"
lab up <<< "$SUDO"; ok "up with a failing playbook: exit 1" "$?" 1
has "the failed run had the marker" "MARKER present site.yml" "$S/calls"
ok "marker removed after a failed run" "$([ -e "$H/alert-maintenance.json" ] && echo present || echo gone)" gone
rm -f "$S/fail_site.yml"
: > "$S/alert_off"; vm absent; fresh
lab up <<< "$SUDO"; ok "up with alerts switched off: exit 0" "$?" 0
hasnot "alerts off: no marker is written" "MARKER present" "$S/calls"
rm -f "$S/alert_off"
vm running; fresh
echo n | lab down; ok "down answered with no: exit 0" "$?" 0
ok "marker removed after an aborted down" "$([ -e "$H/alert-maintenance.json" ] && echo present || echo gone)" gone
vm running; fresh; echo snap1 > "$S/snaps"
lab export <<< "$SUDO"
lab down --yes < /dev/null; ok "down --yes: exit 0" "$?" 0
ok "marker removed after down" "$([ -e "$H/alert-maintenance.json" ] && echo present || echo gone)" gone
has "down says that alerts are paused" "Alerts paused while lab.sh down runs" "$T/out"
vm running; fresh
lab purge --no-export <<< $'s3kr1t\npurge\nk3s-lab\n'; ok "purge: exit 0" "$?" 0
has "purge says that alerts are paused" "Alerts paused while lab.sh purge runs" "$T/out"
ok "marker removed after purge" "$([ -e "$H/alert-maintenance.json" ] && echo present || echo gone)" gone
vm running; : > "$S/rustfs_up"; : > "$S/bucket_used"; fresh

echo "== restore-drill: double confirmation, fresh export required (stubs, nothing real is touched)"
printf '#!/usr/bin/env python3\nimport os, sys\nopen(os.environ["S"] + "/calls", "a").write("fake-tool " + " ".join(sys.argv[1:]) + "\\n")\n' > "$T/fake-lab-tool.py"
vm running; fresh
lab restore-drill --no-export < /dev/null; ok "restore-drill --no-export: exit 1" "$?" 1
has "--no-export is refused with a reason" "--no-export does not apply to restore-drill" "$T/out"
mv "$H/data/vm-export" "$H/data/vm-export.off"
lab restore-drill <<< $'restore-drill\nk3s-lab\n'; ok "without an export: exit 1" "$?" 1
has "refusal names the export" "Run 'bash scripts/lab.sh export' first" "$T/out"
hasnot "restore-drill.yml did not run without an export" "restore-drill.yml" "$S/calls"
mv "$H/data/vm-export.off" "$H/data/vm-export"
lab restore-drill --yes < /dev/null; ok "--yes without an answer: exit 0 (aborted)" "$?" 0
has "--yes does not skip the question (aborts)" "Aborted (nothing changed)" "$T/out"
hasnot "restore-drill.yml did not run (yes)" "restore-drill.yml" "$S/calls"
lab restore-drill <<< $'purge\nk3s-lab\n'; has "the word purge is not accepted" "Aborted" "$T/out"
lab restore-drill <<< $'restore-drill\nfalsch\n'; has "wrong VM name aborts" "Aborted" "$T/out"
hasnot "restore-drill.yml did not run (wrong answers)" "restore-drill.yml" "$S/calls"
vm absent; lab restore-drill <<< $'restore-drill\nk3s-lab\n'; ok "VM missing: exit 1" "$?" 1; vm running
lab restore-drill <<< $'restore-drill\nk3s-lab\n'; ok "restore-drill complete: exit 0" "$?" 0
has "restore-drill.yml ran" "ansible-playbook restore-drill.yml" "$S/calls"
has "result line is shown" "RESTORE-DRILL RESULT ok: database 95 s" "$T/out"
hasnot "no VM was torn down" "tofu destroy" "$S/calls"
hasnot "no bucket was emptied" "lab-backups-empty.yml" "$S/calls"
touch "$S/fail_restore-drill.yml"; lab restore-drill <<< $'restore-drill\nk3s-lab\n'; ok "drill failure: exit 1" "$?" 1; rm -f "$S/fail_restore-drill.yml"
lab help < /dev/null; has "usage lists restore-drill" "lab.sh restore-drill" "$T/out"
lab restore-drill extra < /dev/null; ok "extra argument: exit 1" "$?" 1

echo "== replica and alert subcommands (stub tools)"
rm -f "$H/replica.json" "$H/alert.json"
lab replica status < /dev/null; ok "replica status without config: exit 1" "$?" 1
has "tells how to create the config" "lab.sh replica config" "$T/out"
: > "$H/replica.json"; : > "$H/alert.json"; fresh
lab replica status < /dev/null; ok "replica status: exit 0" "$?" 0
has "status goes to lab-replica with the config" "fake-tool status --config $H/replica.json" "$S/calls"
lab replica verify < /dev/null; has "verify" "fake-tool verify --config $H/replica.json" "$S/calls"
lab replica mirror < /dev/null; has "mirror" "fake-tool mirror --config $H/replica.json" "$S/calls"
lab replica install < /dev/null; ok "replica install: exit 0" "$?" 0
has "install runs the playbook" "ansible-playbook backup-replica.yml" "$S/calls"
lab replica config < /dev/null; has "config only" "ansible-playbook backup-replica.yml --tags config" "$S/calls"
lab replica restore < /dev/null; ok "restore without DIR: exit 1" "$?" 1
lab replica restore "$T/back" < /dev/null; has "restore passes the target" "fake-tool restore --config $H/replica.json --target $T/back" "$S/calls"
lab replica nonsense < /dev/null; ok "unknown replica action: exit 1" "$?" 1
touch "$S/replica_off"; lab replica status < /dev/null; ok "replica switched off: exit 1" "$?" 1; rm -f "$S/replica_off"
lab alert < /dev/null; has "alert default is status" "fake-tool status --config $H/alert.json" "$S/calls"
lab alert run < /dev/null; has "alert run" "fake-tool run --config $H/alert.json" "$S/calls"
lab alert test < /dev/null; has "alert test" "fake-tool test --config $H/alert.json" "$S/calls"
lab alert install < /dev/null; has "alert install" "ansible-playbook backup-alert.yml" "$S/calls"
lab alert verify < /dev/null; has "alert verify" "ansible-playbook verify-alerts.yml" "$S/calls"
lab alert nonsense < /dev/null; ok "unknown alert action: exit 1" "$?" 1
lab alert run extra < /dev/null; ok "too many arguments: exit 1" "$?" 1
lab status extra < /dev/null; ok "status still rejects positional arguments" "$?" 1

echo "== purge: double confirmation"
mkdir -p "$T/repo/infra/envs/local/.terraform"; : > "$T/repo/infra/envs/local/terraform.tfstate"; fresh
lab purge --yes --no-export <<< "$SUDO"; ok "purge with --yes without an answer: exit 0 (aborted)" "$?" 0
has "abort" "Aborted (nothing changed)" "$T/out"
hasnot "purge-host.yml did not run" "purge-host.yml" "$S/calls"
lab purge --no-export <<< $'s3kr1t\nnope\n'; has "wrong word aborts" "Aborted" "$T/out"
lab purge --no-export <<< $'s3kr1t\npurge\nfalsch\n'; has "wrong VM name aborts" "Aborted" "$T/out"
ok "VM unchanged after aborts" "$(cat "$S/vm")" running
hasnot "purge-host.yml has not run yet" "purge-host.yml" "$S/calls"
lab purge --no-export <<< $'s3kr1t\npurge\nk3s-lab\n'; ok "purge complete: exit 0" "$?" 0
has "purge-host.yml with approval" "purge-host.yml -e lab_purge_ok=yes" "$S/calls"
has "all buckets" "lab_empty_scope=all" "$S/calls"
ok "VM weg" "$(cat "$S/vm")" absent
ok "tofu state gone" "$([ -e "$T/repo/infra/envs/local/terraform.tfstate" ] && echo present || echo gone)" gone
ok ".terraform weg" "$([ -d "$T/repo/infra/envs/local/.terraform" ] && echo present || echo gone)" gone
has "final message" "DONE: host cleaned up" "$T/out"

echo "== acceptance"
vm running; : > "$S/rustfs_up"; fresh
lab acceptance <<< "$SUDO"; ok "acceptance: exit 0" "$?" 0
has "ACCEPTANCE PASSED" "ACCEPTANCE PASSED" "$T/out"
has "Proof Gitea" "Restore ok: Commit abc1234" "$T/out"
has "evidence Postgres" "PITR until 2026-10-30" "$T/out"
has "acceptance: public certificate without values is a clear SKIP" "SKIP: public certificate NOT checked" "$T/out"
hasnot "verify-public.yml did not run without values" "verify-public.yml" "$S/calls"
has "verify-certmanager.yml lief" "verify-certmanager.yml" "$S/calls"
has "acceptance: verify-egress.yml ran" "verify-egress.yml" "$S/calls"
has "acceptance: verify-consistency.yml lief" "verify-consistency.yml" "$S/calls"
has "acceptance: verify-budget.yml ran" "verify-budget.yml" "$S/calls"
has "acceptance: Memory-Phase im Log" "Memory budget: limits fit into the VM" "$T/out"
ok "acceptance: memory peaks are in the log folder" "$([ -s "$H/data/logs/memory-peaks.json" ] && echo present || echo missing)" present
: > "$S/acme_active_flag"; fresh
lab acceptance <<< "$SUDO"; ok "acceptance with acme_*: exit 0" "$?" 0
has "acceptance with acme_*: verify-public.yml ran" "verify-public.yml" "$S/calls"
hasnot "acceptance with acme_*: no SKIP" "public certificate NOT checked" "$T/out"
: > "$S/fail_verify-public.yml"; fresh
lab acceptance <<< "$SUDO"; ok "acceptance: verify-public.yml red -> exit 1" "$?" 1
rm -f "$S/fail_verify-public.yml"
fresh; lab up <<< "$SUDO"; ok "up with acme_*: exit 0" "$?" 0
has "up with acme_*: public.yml ran" "ansible-playbook public.yml" "$S/calls"
rm -f "$S/acme_active_flag"; fresh
has "timing table" "TOTAL" "$T/out"
L=$(first "$H/data/logs" "lab-acceptance-*.log")
ok "acceptance log mode 600" "$(stat -c %a "$L")" 600
: > "$S/fail_verify-gitea.yml"; fresh
lab acceptance <<< "$SUDO"; ok "acceptance with an error: exit 1" "$?" 1
has "NOT PASSED" "NOT PASSED" "$T/out"
has "verify-cnpg ran anyway" "verify-cnpg.yml" "$S/calls"
rm -f "$S/fail_verify-gitea.yml"
vm absent
lab acceptance <<< "$SUDO"; ok "acceptance without VM: exit 1" "$?" 1

echo "== budget"
PEAKS="$H/data/logs/memory-peaks.json"
cp "$PEAKS" "$T/peaks.keep"
lab budget < /dev/null; ok "budget: Exit 0" "$?" 0
has "budget: report" "namespace/workload/container" "$T/out"
has "budget: without --apply only a note" "Dry look only" "$T/out"
rm -f "$PEAKS"
lab budget < /dev/null; ok "budget without a measurement: exit 1" "$?" 1
has "budget without a measurement: says what to do" "No memory measurement yet" "$T/out"
lab status --apply < /dev/null; ok "--apply on status: exit 1" "$?" 1
has "--apply on status: message" "--apply only applies to budget." "$T/out"
cat > "$PEAKS" << 'JSON'
{"containers": {"argocd/argocd-server/server": {"peak_mib": 100, "samples": 3}},
 "node": {"used_mib_max": 0, "overhead_mib_max": 0, "kube_system_mib_max": 0, "pressure_seen": false}, "samples": 3, "measured": "2026-10-30"}
JSON
cp "$T/repo/infra/envs/local/lab.yaml" "$T/lab.yaml.keep"
lab budget --apply < /dev/null; ok "budget --apply: Exit 0" "$?" 0
has "budget --apply: next step" "ansible-playbook argocd.yml" "$T/out"
cp "$T/lab.yaml.keep" "$T/repo/infra/envs/local/lab.yaml"

echo "== sync-host: new service on a running VM (argocd.yml, then backup-host.yml)"
vm running; : > "$S/rustfs_up"; fresh
lab sync-host <<< "$SUDO"; ok "sync-host: exit 0" "$?" 0
has "sync-host: argocd.yml ran" "ansible-playbook argocd.yml" "$S/calls"
has "sync-host: backup-host.yml ran with the password via stdin" "ansible-playbook backup-host.yml --become-password-file -" "$S/calls"
a=$(line "ansible-playbook argocd.yml"); b=$(line "ansible-playbook backup-host.yml")
ok "sync-host: argocd.yml before backup-host.yml" "$([ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && echo yes || echo no)" yes
hasnot "sync-host: site.yml did not run" "site.yml" "$S/calls"
hasnot "sync-host: no tofu call" "tofu " "$S/calls"
hasnot "sync-host: no VM change" "virsh shutdown" "$S/calls"
hasnot "sync-host: password not in the call list" "s3kr1t" "$S/calls"
has "sync-host: says what it did" "DONE: Argo CD and /etc/hosts follow git" "$T/out"
has "sync-host: shows changed" "Total changed=" "$T/out"
: > "$S/fail_argocd.yml"; fresh
lab sync-host <<< "$SUDO"; ok "sync-host: argocd.yml red -> exit 1" "$?" 1
hasnot "sync-host: backup-host.yml does not run after a red argocd.yml" "ansible-playbook backup-host.yml" "$S/calls"
rm -f "$S/fail_argocd.yml"; fresh
lab sync-host extra < /dev/null; ok "sync-host with a stray argument: exit 1" "$?" 1
vm absent
lab sync-host <<< "$SUDO"; ok "sync-host without VM: exit 1" "$?" 1
has "sync-host without VM: says so" "is not running" "$T/out"
vm running
lab help < /dev/null; has "help lists sync-host" "lab.sh sync-host" "$T/out"

echo "== Secrets map at acceptance and rebuild (display only, never fails)"
vm running; : > "$S/rustfs_up"; fresh
lab acceptance <<< "$SUDO"; ok "acceptance with the map: exit 0" "$?" 0
has "acceptance shows the secrets map" "Secrets map (never shows values)" "$T/out"
: > "$S/ansible_geh_fail"
lab acceptance <<< "$SUDO"; ok "map not readable: acceptance stays exit 0" "$?" 0
has "message map not readable" "Secrets map not readable" "$T/out"
rm -f "$S/ansible_geh_fail"
lab export <<< "$SUDO"; fresh
lab rebuild --yes <<< "$SUDO"; ok "rebuild with map: exit 0" "$?" 0
has "rebuild shows the secrets map" "Secrets map (never shows values)" "$T/out"
lab status --dry-run < /dev/null; ok "--dry-run only for init: exit 1" "$?" 1
has "message only for init" "only applies to init, customize, ca-rotation and repo-egress" "$T/out"

echo "== Docs and single-source list (docs/reference/secrets-map.md)"
SECRETS_YML=$R/ansible/inventory/group_vars/all/secrets.yml
NAMES=$(sed -n 's/^  - name: //p' "$SECRETS_YML")
ok "list has entries" "$([ -n "$NAMES" ] && echo yes || echo no)" yes
# Names whose docs text is still to come (skipped visibly until docs/reference/secrets-map.md names them).
# Empty: the docs name every entry of the list, so every entry gets the normal check.
DOC_PENDING=""
for nm in $NAMES; do
  if [[ $DOC_PENDING == *" $nm "* ]] && ! grep -Fq -- "\`$nm\`" "$R/docs/reference/secrets-map.md"; then
    echo "SKIP $nm: docs text pending (CHANGES-wave2.md)"
    continue
  fi
  has "docs name $nm" "\`$nm\`" "$R/docs/reference/secrets-map.md"
done
has "docs name the notes sites" "notes-<site>-deploy" "$R/docs/reference/secrets-map.md"
has "docs name init" "lab.sh init" "$R/docs/reference/secrets-map.md"
has "docs name --new-age-key" "--new-age-key" "$R/docs/reference/secrets-map.md"
has "docs name the Argo copy command" "argocd-initial-admin-secret" "$R/docs/reference/secrets-map.md"


echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
