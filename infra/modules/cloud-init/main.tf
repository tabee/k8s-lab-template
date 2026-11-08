# The ONE cloud-init template of every environment (lab VM and cloud server): same user,
# same SSH key, no password login. Hardening follows with Ansible.
# The module only renders text, it creates no resource.

variable "hostname" {
  description = "Short hostname in the guest."
  type        = string
}

variable "fqdn" {
  description = "Fully qualified name (hostname + lab domain)."
  type        = string
}

variable "username" {
  description = "The only user (sudo without password, no password login)."
  type        = string
}

variable "ssh_public_key" {
  description = "Public key of that user (one line)."
  type        = string
}

variable "guest_agent" {
  description = "true installs and starts qemu-guest-agent (needed by libvirt, not by a cloud server)."
  type        = bool
  default     = false
}

output "user_data" {
  description = "The cloud-config text."
  value = templatefile("${path.module}/user-data.yaml.tftpl", {
    hostname       = var.hostname
    fqdn           = var.fqdn
    username       = var.username
    ssh_public_key = trimspace(var.ssh_public_key)
    guest_agent    = var.guest_agent
  })
}
