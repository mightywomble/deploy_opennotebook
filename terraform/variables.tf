variable "api_key" {
  description = "Cudo API key"
  type        = string
  sensitive   = true
}

variable "project_id" {
  description = "Cudo project ID"
  type        = string
}

variable "data_center_id" {
  description = "Cudo data center ID (e.g., gb-bournemouth-1)"
  type        = string
}

variable "image_id" {
  description = "OS image identifier (e.g., ubuntu-24-04)"
  type        = string
}

variable "vcpus" {
  description = "Number of vCPUs for the VM"
  type        = number
}

variable "memory_gib" {
  description = "RAM in GiB for the VM"
  type        = number
}

variable "boot_disk_size" {
  description = "Boot disk size in GiB"
  # Intentionally leaving type unspecified to accept number or string (matches current tfvars)
}

variable "ssh_key_source" {
  description = "Where to pull SSH keys from: user, project, or custom"
  type        = string
}

# The VM ID to assign to the cudo_vm resource (human-readable identifier)
variable "vm_id" {
  description = "Identifier for the VM (used as cudo_vm.instance id)"
  type        = string
}

# Web VM identifier (second server)
variable "vm_id_web" {
  description = "Identifier for the web VM (used as cudo_vm.web_instance id)"
  type        = string
  default     = "opennotebookweb"
}

# Optional overrides for web VM sizing; fall back to primary if unset
variable "vcpus_web" {
  description = "Number of vCPUs for the web VM (defaults to vcpus)"
  type        = number
  default     = 0
}

variable "memory_gib_web" {
  description = "RAM in GiB for the web VM (defaults to memory_gib)"
  type        = number
  default     = 0
}

variable "boot_disk_size_web" {
  description = "Boot disk size in GiB for the web VM (defaults to boot_disk_size)"
}


# Cloudflare API token passed securely from Terraform into the VM's start_script
variable "cf_api_token" {
  description = "Cloudflare API token used by bootstrap.sh"
  type        = string
  sensitive   = true
}

# URL where the VM can download the bootstrap.sh (must be reachable from the VM)
variable "bootstrap_url" {
  description = "Public URL to fetch bootstrap.sh during first boot"
  type        = string
}

# Cloudflare Origin certificate and private key (PEM) to avoid API creation
variable "cf_origin_cert_pem" {
  description = "Cloudflare Origin certificate (PEM) for the FULL_DOMAIN"
  type        = string
  sensitive   = true
}

variable "cf_origin_key_pem" {
  description = "Cloudflare Origin private key (PEM) for the FULL_DOMAIN"
  type        = string
  sensitive   = true
}

# --- Ansible pull configuration ---
variable "ansible_repo_url" {
  description = "Git URL for the Ansible repository (e.g., git@github.com:OWNER/REPO.git)"
  type        = string
}

variable "ansible_repo_ref" {
  description = "Git ref/branch for ansible-pull"
  type        = string
  default     = "main"
}

variable "ansible_playbook" {
  description = "Path to playbook within the repo (e.g., ansible/deploy/site.yml)"
  type        = string
  default     = "ansible/deploy/site.yml"
}

variable "ansible_repo_ssh_key" {
  description = "Private SSH key used to access the Ansible repo (optional if repo is public)"
  type        = string
  sensitive   = true
  default     = ""
}

# Web app playbook path (invoked on the second server)
variable "ansible_playbook_web" {
  description = "Playbook path to run on the web VM"
  type        = string
  default     = "ansible/deploy/site_web.yml"
}

# API base URL passed to the web VM; typically http://<opennotebook_ip>:5055
variable "api_base" {
  description = "API base URL used by the web app (e.g., http://<opennotebook_ip>:5055)"
  type        = string
  default     = ""
}
