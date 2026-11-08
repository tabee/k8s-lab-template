# Provider pinned exactly: 0.9.x has a completely new schema compared to 0.8.x,
# an update must therefore happen deliberately.
terraform {
  required_version = ">= 1.8.0"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "= 0.9.9"
    }
  }
}
