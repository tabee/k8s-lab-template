# One Ubuntu 24.04 VM on libvirt, Schema dmacvicar/libvirt 0.9.x.
# 0.9.x maps the libvirt XML almost 1:1: nested objects "= { ... }".

# Shared with every other environment (infra/modules/cloud-init): one template, not a copy.
module "cloud_init" {
  source = "../cloud-init"

  hostname       = var.name
  fqdn           = local.fqdn
  username       = var.username
  ssh_public_key = var.ssh_public_key
  guest_agent    = true
}

locals {
  fqdn = "${var.name}.${var.domain}"

  # Deterministic MAC from the IP, so that network-config and NIC match.
  ip_octets   = split(".", var.ip_address)
  mac_address = coalesce(var.mac_address, format("52:54:00:%02x:%02x:%02x", tonumber(local.ip_octets[1]), tonumber(local.ip_octets[2]), tonumber(local.ip_octets[3])))

  user_data = module.cloud_init.user_data

  # instance-id decides whether cloud-init runs "for the first time".
  meta_data = yamlencode({
    "instance-id"    = var.name
    "local-hostname" = var.name
  })

  # Static IP via netplan v2. The NIC is found via the MAC,
  # the interface name in the guest (enp1s0 or similar) is therefore irrelevant.
  network_config = yamlencode({
    version = 2
    ethernets = {
      primary = {
        match       = { macaddress = local.mac_address }
        dhcp4       = false
        addresses   = ["${var.ip_address}/${var.prefix_length}"]
        routes      = [{ to = "default", via = var.gateway }]
        nameservers = { addresses = var.dns_servers }
      }
    }
  })
}

# Base image: load into the pool once, never change.
resource "libvirt_volume" "base" {
  name = var.base_volume_name
  pool = var.pool_name
  target = {
    format = { type = "qcow2" }
    # Base image is read-only and public: QEMU (libvirt-qemu) must be able to read it
    # as a backing file. The provider otherwise creates root:root 0600.
    permissions = { mode = "0644" }
  }
  create = { content = { url = var.image_url } }

  lifecycle {
    # The base image is loaded once and never re-pulled: a new URL
    # replaces neither the volume nor the VM built on it.
    ignore_changes = [create]

    # Pinned: if the image is local (absolute path), its SHA-256 must match the
    # pin. Empty pin = no check (e.g. for an https URL).
    # If the file is missing (e.g. on teardown), no check is done: lab.sh up
    # downloads and checks the image itself before every apply.
    precondition {
      condition     = (var.image_sha256 == "" || !startswith(var.image_url, "/") || !fileexists(var.image_url)) ? true : filesha256(var.image_url) == var.image_sha256
      error_message = "The SHA-256 of the base image ${var.image_url} differs from the pin image_sha256 (lab.yaml). Reload the image: bash scripts/lab.sh up."
    }
  }
}

# VM disk: qcow2 overlay on the base image. Only changes land here.
# cloud-init enlarges the root partition automatically on first boot.
resource "libvirt_volume" "disk" {
  name     = "${var.name}.qcow2"
  pool     = var.pool_name
  capacity = var.disk_gb * 1024 * 1024 * 1024 # GiB -> Bytes
  target   = { format = { type = "qcow2" } }
  backing_store = {
    path   = libvirt_volume.base.path
    format = { type = "qcow2" }
  }
}

# Seed ISO (label "cidata") with user-data, meta-data and network-config.
# The provider builds it itself, genisoimage is not needed.
resource "libvirt_cloudinit_disk" "seed" {
  name           = "${var.name}-cloudinit"
  user_data      = local.user_data
  meta_data      = local.meta_data
  network_config = local.network_config
}

# Upload seed ISO into the pool, so that QEMU can access it.
resource "libvirt_volume" "seed" {
  name   = "${var.name}-cloudinit.iso"
  pool   = var.pool_name
  create = { content = { url = libvirt_cloudinit_disk.seed.path } }

  # The source is in /tmp and is gone after a host reboot. cloud-init
  # runs only on first boot anyway, so ignore this change.
  # Rebuild deliberately: tofu apply -replace=...
  lifecycle {
    ignore_changes = [create]
  }
}

resource "libvirt_domain" "this" {
  name        = var.name
  type        = "kvm"
  vcpu        = var.vcpu
  memory      = var.memory_mib
  memory_unit = "MiB"

  running   = true
  autostart = var.autostart

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  # ACPI: so that a host shutdown can shut the VM down cleanly.
  features = {
    acpi = true
    apic = {}
  }

  # Pass through host CPU: best performance for k3s.
  cpu = { mode = "host-passthrough" }

  devices = {
    # Disks as type='file' (path) instead of type='volume' (pool reference):
    # virt-aa-helper builds the AppArmor profile only from the domain XML and
    # cannot resolve pool/volume references. Likewise the
    # backing chain must be declared explicitly, otherwise the base image is missing
    # in the profile and QEMU gets "Permission denied".
    disks = [
      {
        source = { file = { file = libvirt_volume.disk.path } }
        target = { dev = "vda", bus = "virtio" }
        driver = { type = "qcow2" }
        backing_store = {
          source = { file = { file = libvirt_volume.base.path } }
          format = { type = "qcow2" }
        }
      },
      {
        device = "cdrom"
        source = { file = { file = libvirt_volume.seed.path } }
        target = { dev = "sda", bus = "sata" }
      },
    ]

    interfaces = [
      {
        model  = { type = "virtio" }
        mac    = { address = local.mac_address }
        source = { network = { network = var.network_name } }
      },
    ]

    # Serial console for "virsh console".
    serials = [{ target = { port = 0 } }]

    # Channel for the qemu-guest-agent (query IP, clean shutdown).
    channels = [
      {
        source = { unix = { mode = "bind" } }
        target = { virt_io = { name = "org.qemu.guest_agent.0" } }
      },
    ]
  }
}
