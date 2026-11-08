# All values of the lab VM come from lab.yaml (one source, also for Ansible and
# scripts/lab.sh). Own values: lab.local.yaml next to it (overrides per key).
# There are deliberately no variables.tf and no *.auto.tfvars any more.
locals {
  lab_basis = yamldecode(file("${path.module}/lab.yaml"))
  # If the file is missing or contains only comments, it stays empty.
  lab_local_raw = fileexists("${path.module}/lab.local.yaml") ? file("${path.module}/lab.local.yaml") : "{}"
  # No try(): a typo in lab.local.yaml should fail loudly, not be ignored silently.
  # merge() skips null (empty file) and also mixes numbers, texts and lists.
  lab = merge(local.lab_basis, yamldecode(local.lab_local_raw))

  # Prefix length from vm_cidr (192.168.122.0/24 -> 24): one value less to maintain.
  prefix_length = tonumber(split("/", local.lab.vm_cidr)[1])

  # The base image lies pinned in the local cache (scripts/lab.sh downloads and
  # checks it). The module checks the SHA-256 a second time at plan.
  image_path = "${pathexpand(local.lab.image_cache_dir)}/${local.lab.image_file}"
}
