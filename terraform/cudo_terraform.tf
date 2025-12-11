terraform {
  required_providers {
    cudo = {
      source  = "CudoVentures/cudo"
      version = "0.11.2"
    }
  }
}

provider "cudo" {
  api_key    = var.api_key
  project_id = var.project_id
}

# 1TB storage disk to attach to the VM
resource "cudo_storage_disk" "ubuntu_mirror_storage" {
  data_center_id = var.data_center_id
  id             = "${replace(var.vm_id, "_", "-")}-aptstorage"
  size_gib       = 20
}

# Single VM for the Ubuntu mirror
resource "cudo_vm" "instance" {
  depends_on     = [cudo_storage_disk.ubuntu_mirror_storage]
  id             = replace(var.vm_id, "_", "-")
  machine_type   = "intel-broadwell"
  data_center_id = var.data_center_id
  memory_gib     = var.memory_gib
  vcpus          = var.vcpus
  boot_disk = {
    image_id = var.image_id
    size_gib = var.boot_disk_size
  }
  storage_disks = [
    {
      disk_id = cudo_storage_disk.ubuntu_mirror_storage.id
    }
  ]
  ssh_key_source = var.ssh_key_source

  # Run our bootstrap on first boot. We render a small wrapper that exports CF_API_TOKEN
  # and then executes the contents of bootstrap.sh under bash.
start_script = templatefile(
    "${path.module}/templates/start_script.sh.tpl",
    {
      cf_api_token         = var.cf_api_token
      bootstrap_url        = var.bootstrap_url
      cf_origin_cert_pem   = var.cf_origin_cert_pem
      cf_origin_key_pem    = var.cf_origin_key_pem
      ansible_repo_url     = var.ansible_repo_url
      ansible_repo_ref     = var.ansible_repo_ref
      ansible_playbook     = var.ansible_playbook
      ansible_repo_ssh_key = var.ansible_repo_ssh_key
    }
  )
}
