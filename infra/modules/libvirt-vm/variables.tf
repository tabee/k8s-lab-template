# Input values of the module. The defaults are generic, the real values
# come from the environment (infra/envs/<env>/local.auto.tfvars).

variable "name" {
  description = "Name of the VM (libvirt domain) and hostname in the guest."
  type        = string
  default     = "k3s-lab"
}

variable "domain" {
  description = "Lab-Domain, together with name gives the FQDN."
  type        = string
}

variable "vcpu" {
  type    = number
  default = 2
}

variable "memory_mib" {
  type    = number
  default = 4096
}

variable "disk_gb" {
  description = "Size of the VM disk in GiB."
  type        = number
  default     = 40
}

variable "pool_name" {
  description = "libvirt storage pool for base image, disk and seed ISO."
  type        = string
  default     = "default"
}

variable "network_name" {
  type    = string
  default = "default"
}

variable "ip_address" {
  description = "Static IPv4 of the VM (per cloud-init network-config)."
  type        = string
  validation {
    condition     = can(cidrhost("${var.ip_address}/32", 0))
    error_message = "ip_address must be a valid IPv4 address."
  }
}

variable "prefix_length" {
  type    = number
  default = 24
}

variable "gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "mac_address" {
  description = "Fixed MAC. Empty = derived from the IP (52:54:00:xx:xx:xx)."
  type        = string
  default     = null
}

variable "username" {
  description = "Login user in the guest (sudo without password, SSH key only)."
  type        = string
}

variable "ssh_public_key" {
  description = "Content of the public SSH key (one line)."
  type        = string
  validation {
    condition     = can(regex("^(ssh-|ecdsa-|sk-)", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key does not look like an OpenSSH public key."
  }
}

variable "image_url" {
  description = "Ubuntu Cloud-Image (qcow2, even if the extension is .img): absolute path of a local file or URL. No default: the value comes from lab.yaml."
  type        = string
}

variable "image_sha256" {
  description = "SHA-256 des Basis-Images (Pin). Checked if image_url is a local path. Empty = do not check."
  type        = string
  default     = ""
}

variable "base_volume_name" {
  type    = string
  default = "ubuntu-24.04-noble-base.qcow2"
}

variable "autostart" {
  description = "Start VM when the host boots (lesson from the power outage)."
  type        = bool
  default     = true
}
