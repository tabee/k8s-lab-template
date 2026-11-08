output "name" { value = libvirt_domain.this.name }
output "fqdn" { value = local.fqdn }
output "ip" { value = var.ip_address }
output "mac_address" { value = local.mac_address }
output "username" { value = var.username }
