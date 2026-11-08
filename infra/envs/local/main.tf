# Environment "local": the k3s lab VM on the owner's desktop.
terraform {
  required_version = ">= 1.8.0"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "= 0.9.9"
    }
  }
}

# System daemon (not qemu:///session), so that network 'default' and autostart work.
provider "libvirt" {
  uri = local.lab.libvirt_uri
}

module "k3s_lab" {
  source = "../../modules/libvirt-vm"

  # All values are in lab.yaml (locals.tf), one source for Tofu, Ansible and lab.sh.
  name          = local.lab.vm_name
  domain        = local.lab.domain
  vcpu          = local.lab.vcpu
  memory_mib    = local.lab.memory_mib
  disk_gb       = local.lab.disk_gb
  network_name  = local.lab.network_name
  ip_address    = local.lab.vm_ip
  prefix_length = local.prefix_length
  gateway       = local.lab.gateway
  dns_servers   = local.lab.dns_servers
  username      = local.lab.ssh_user
  image_url     = local.image_path
  image_sha256  = local.lab.image_sha256

  # Public key directly from ~/.ssh, no secret in the repo.
  ssh_public_key = file(pathexpand("${local.lab.ssh_key}.pub"))
}
