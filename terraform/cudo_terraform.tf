terraform {
  required_providers {
    cudo = {
      source  = "CudoVentures/cudo"
      version = "0.11.2"
    }
  }
}

# Second VM: opennotebookweb
resource "cudo_vm" "web_instance" {
  depends_on     = [cudo_vm.instance]
  id             = replace(var.vm_id_web, "_", "-")
  machine_type   = (var.machine_type_web != "" ? var.machine_type_web : (var.machine_type != "" ? var.machine_type : "intel-broadwell"))
  data_center_id = var.data_center_id
  memory_gib     = var.memory_gib_web != 0 ? var.memory_gib_web : var.memory_gib
  vcpus          = var.vcpus_web != 0 ? var.vcpus_web : var.vcpus
  boot_disk = {
    image_id = var.image_id
    size_gib = coalesce(var.boot_disk_size_web, var.boot_disk_size)
  }
  ssh_key_source = var.ssh_key_source

  # Render start script for web node: run the web playbook and pass API_BASE
start_script = templatefile(
    "${path.module}/templates/start_script.sh.tpl",
    {
      cf_api_token         = var.cf_api_token
      bootstrap_url        = var.bootstrap_url
      cf_origin_cert_pem   = var.cf_origin_cert_pem
      cf_origin_key_pem    = var.cf_origin_key_pem
      ansible_repo_url     = var.ansible_repo_url
      ansible_repo_ref     = var.ansible_repo_ref
      ansible_playbook     = var.ansible_playbook_web
      ansible_repo_ssh_key = var.ansible_repo_ssh_key
      # Disk/mount variables for bootstrap
      data_disk_device     = var.data_disk_device
      data_partition_device= var.data_partition_device
      data_mount_point     = var.data_mount_point
      # Web app variables
      ainotebook_repo_url  = var.ainotebook_repo_url
      ainotebook_repo_ref  = var.ainotebook_repo_ref
      ainotebook_app_dir   = var.ainotebook_app_dir
      ainotebook_streamlit_port = var.ainotebook_streamlit_port
      ainotebook_service_name   = var.ainotebook_service_name
      api_base             = var.api_base
    }
  )
}

provider "cudo" {
  api_key    = var.api_key
  project_id = var.project_id
}




# Single VM for the Ubuntu mirror (primary)
resource "cudo_vm" "instance" {
  id             = replace(var.vm_id, "_", "-")
  machine_type   = (var.machine_type != "" ? var.machine_type : "intel-broadwell")
  data_center_id = var.data_center_id
  memory_gib     = var.memory_gib
  vcpus          = var.vcpus
  boot_disk = {
    image_id = var.image_id
    size_gib = var.boot_disk_size
  }
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
      # Disk/mount variables for bootstrap
      data_disk_device     = var.data_disk_device
      data_partition_device= var.data_partition_device
      data_mount_point     = var.data_mount_point
      # Web app defaults (harmless on primary)
      ainotebook_repo_url  = var.ainotebook_repo_url
      ainotebook_repo_ref  = var.ainotebook_repo_ref
      ainotebook_app_dir   = var.ainotebook_app_dir
      ainotebook_streamlit_port = var.ainotebook_streamlit_port
      ainotebook_service_name   = var.ainotebook_service_name
      # Avoid cycle: do not derive api_base from this VM's own IP
      api_base             = var.api_base
    }
  )
}
