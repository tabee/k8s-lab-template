output "ip" { value = module.k3s_lab.ip }
output "mac_address" { value = module.k3s_lab.mac_address }
output "ssh_command" {
  value = "ssh -i ${local.lab.ssh_key} ${module.k3s_lab.username}@${module.k3s_lab.ip}"
}
