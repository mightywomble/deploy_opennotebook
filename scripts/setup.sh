#!/usr/bin/env bash
set -Eeuo pipefail

# Interactive setup for Terraform + Ansible in this repo.
# - Prompts for variables (with sensible defaults)
# - Writes non-secrets to terraform/terraform.tfvars
# - Writes secrets to terraform/secrets.auto.tfvars (0600)
# - Runs terraform init/plan/apply

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
TF_DIR="$REPO_ROOT/terraform"
SECRETS_FILE="$TF_DIR/secrets.auto.tfvars"
TFVARS_FILE="$TF_DIR/terraform.tfvars"

# --- helpers ---
color() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
info() { echo "$(color 36 "[INFO]") $*"; }
warn() { echo "$(color 33 "[WARN]") $*"; }
err() { echo "$(color 31 "[ERR]")  $*"; }

prompt() {
  local q="$1"; local def="${2:-}"; local var
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " var || true
    echo "${var:-$def}"
  else
    read -r -p "$q: " var || true
    echo "${var:-}"
  fi
}

prompt_secret() {
  local q="$1"; local def_note="${2:-}"; local var
  if [[ -n "$def_note" ]]; then
    read -r -s -p "$q (leave empty to keep current): " var || true; echo
    echo "${var:-}"
  else
    read -r -s -p "$q: " var || true; echo
    echo "${var:-}"
  fi
}

prompt_multiline() {
  local q="$1"; local existing_note="${2:-}"
  echo "$q (end with a single line containing EOF). ${existing_note}"
  local line content=""
  while IFS= read -r line; do
    [[ "$line" == "EOF" ]] && break
    content+="$line
"
  done
  echo -n "$content"
}

mask() {
  local s="$1"; local n=${#s}
  if (( n == 0 )); then echo "(empty)"; return; fi
  if (( n <= 8 )); then echo "****"; return; fi
  echo "${s:0:4}****${s: -4}"
}

# Default from git when possible
GIT_REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")"
GIT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

# Load existing tfvars to supply defaults
existing_val() {
  local key="$1"; local file="$2"
  [[ -f "$file" ]] || { echo ""; return; }
  # naive extraction for key = value (strings or numbers)
  awk -v k="$key" 'BEGIN{FS="="} $1 ~ "^"k"[[:space:]]*$" {sub(/^[[:space:]]+/,"",$2); gsub(/[\" ]/ ,"",$2); print $2}' "$file" | tail -n1
}

DEF_vm_id="$(existing_val vm_id "$TFVARS_FILE")"
DEF_vm_id_web="$(existing_val vm_id_web "$TFVARS_FILE")"
DEF_project_id="$(existing_val project_id "$TFVARS_FILE")"
DEF_data_center_id="$(existing_val data_center_id "$TFVARS_FILE")"
DEF_image_id="$(existing_val image_id "$TFVARS_FILE")"
DEF_machine_type="$(existing_val machine_type "$TFVARS_FILE")"; DEF_machine_type="${DEF_machine_type:-intel-broadwell}"
DEF_machine_type_web="$(existing_val machine_type_web "$TFVARS_FILE")"
DEF_vcpus="$(existing_val vcpus "$TFVARS_FILE")"; DEF_vcpus="${DEF_vcpus:-4}"
DEF_memory_gib="$(existing_val memory_gib "$TFVARS_FILE")"; DEF_memory_gib="${DEF_memory_gib:-8}"
DEF_boot_disk_size="$(existing_val boot_disk_size "$TFVARS_FILE")"; DEF_boot_disk_size="${DEF_boot_disk_size:-50}"
DEF_storage_disk_size="$(existing_val storage_disk_size "$TFVARS_FILE")"; DEF_storage_disk_size="${DEF_storage_disk_size:-20}"
DEF_storage_disk2_size="$(existing_val storage_disk2_size "$TFVARS_FILE")"; DEF_storage_disk2_size="${DEF_storage_disk2_size:-0}"
DEF_vcpus_web="$(existing_val vcpus_web "$TFVARS_FILE")"
DEF_memory_gib_web="$(existing_val memory_gib_web "$TFVARS_FILE")"
DEF_boot_disk_size_web="$(existing_val boot_disk_size_web "$TFVARS_FILE")"
DEF_storage_disk_size_web="$(existing_val storage_disk_size_web "$TFVARS_FILE")"
DEF_storage_disk2_size_web="$(existing_val storage_disk2_size_web "$TFVARS_FILE")"
DEF_ssh_key_source="$(existing_val ssh_key_source "$TFVARS_FILE")"; DEF_ssh_key_source="${DEF_ssh_key_source:-user}"

# Disk layout defaults
DEF_data_disk_device="$(existing_val data_disk_device "$TFVARS_FILE")"; DEF_data_disk_device="${DEF_data_disk_device:-/dev/sdb}"
DEF_data_partition_device="$(existing_val data_partition_device "$TFVARS_FILE")"; DEF_data_partition_device="${DEF_data_partition_device:-/dev/sdb1}"
DEF_data_mount_point="$(existing_val data_mount_point "$TFVARS_FILE")"; DEF_data_mount_point="${DEF_data_mount_point:-/opt/apt}"
DEF_data_disk2_device="$(existing_val data_disk2_device "$TFVARS_FILE")"; DEF_data_disk2_device="${DEF_data_disk2_device:-/dev/sdc}"
DEF_data_partition2_device="$(existing_val data_partition2_device "$TFVARS_FILE")"; DEF_data_partition2_device="${DEF_data_partition2_device:-/dev/sdc1}"
DEF_data_mount2_point="$(existing_val data_mount2_point "$TFVARS_FILE")"; DEF_data_mount2_point="${DEF_data_mount2_point:-/opt/data2}"

# Ansible-pull repo (this repo) and web app repo defaults
DEF_ansible_repo_url="$(existing_val ansible_repo_url "$SECRETS_FILE")"; DEF_ansible_repo_url="${DEF_ansible_repo_url:-$GIT_REMOTE_URL}"
DEF_ansible_repo_ref="$(existing_val ansible_repo_ref "$SECRETS_FILE")"; DEF_ansible_repo_ref="${DEF_ansible_repo_ref:-$GIT_BRANCH}"
DEF_ansible_playbook="$(existing_val ansible_playbook "$SECRETS_FILE")"; DEF_ansible_playbook="${DEF_ansible_playbook:-ansible/deploy/site.yml}"
DEF_ansible_playbook_web="$(existing_val ansible_playbook_web "$SECRETS_FILE")"; DEF_ansible_playbook_web="${DEF_ansible_playbook_web:-ansible/deploy/site_web.yml}"
DEF_ainotebook_repo_url="$(existing_val ainotebook_repo_url "$TFVARS_FILE")"; DEF_ainotebook_repo_url="${DEF_ainotebook_repo_url:-git@github.com:mightywomble/ainotebook.git}"
DEF_ainotebook_repo_ref="$(existing_val ainotebook_repo_ref "$TFVARS_FILE")"; DEF_ainotebook_repo_ref="${DEF_ainotebook_repo_ref:-main}"
DEF_ainotebook_app_dir="$(existing_val ainotebook_app_dir "$TFVARS_FILE")"; DEF_ainotebook_app_dir="${DEF_ainotebook_app_dir:-/opt/ainotebook}"
DEF_ainotebook_streamlit_port="$(existing_val ainotebook_streamlit_port "$TFVARS_FILE")"; DEF_ainotebook_streamlit_port="${DEF_ainotebook_streamlit_port:-8501}"
DEF_ainotebook_service_name="$(existing_val ainotebook_service_name "$TFVARS_FILE")"; DEF_ainotebook_service_name="${DEF_ainotebook_service_name:-ainotebook.service}"

# bootstrap URL default (keep existing if present)
DEF_bootstrap_url="$(awk -F'=' '/^\s*bootstrap_url/ {sub(/^\s+|\s+$/,"",$2); gsub(/[\" ]/,"",$2); print $2}' "$SECRETS_FILE" 2>/dev/null | tail -n1)"

# --- prompts ---
info "Primary VM (opennotebook)"
vm_id=$(prompt "Primary VM id" "${DEF_vm_id:-opennotebook}")
project_id=$(prompt "Cudo project_id" "${DEF_project_id:-}")
data_center_id=$(prompt "Cudo data_center_id" "${DEF_data_center_id:-gb-bournemouth-1}")
image_id=$(prompt "Image id" "${DEF_image_id:-ubuntu-2404}")
machine_type=$(prompt "Machine type" "$DEF_machine_type")
vcpus=$(prompt "vCPUs" "$DEF_vcpus")
memory_gib=$(prompt "Memory GiB" "$DEF_memory_gib")
boot_disk_size=$(prompt "Boot disk size (GiB)" "$DEF_boot_disk_size")
storage_disk_size=$(prompt "Data disk size (GiB)" "$DEF_storage_disk_size")
storage_disk2_size=$(prompt "Second data disk size (GiB, 0=disable)" "$DEF_storage_disk2_size")
ssh_key_source=$(prompt "SSH key source (user|project|custom)" "$DEF_ssh_key_source")

info "Web VM (opennotebookweb)"
vm_id_web=$(prompt "Web VM id" "${DEF_vm_id_web:-opennotebookweb}")
machine_type_web=$(prompt "Web machine type (empty to inherit)" "${DEF_machine_type_web:-}")
vcpus_web=$(prompt "Web vCPUs (empty to inherit)" "${DEF_vcpus_web:-}")
memory_gib_web=$(prompt "Web Memory GiB (empty to inherit)" "${DEF_memory_gib_web:-}")
boot_disk_size_web=$(prompt "Web boot disk size GiB (empty to inherit)" "${DEF_boot_disk_size_web:-}")
storage_disk_size_web=$(prompt "Web data disk size GiB (empty -> inherit primary)" "${DEF_storage_disk_size_web:-}")
storage_disk2_size_web=$(prompt "Web second data disk size GiB (0=disable)" "${DEF_storage_disk2_size_web:-0}")

info "Disk layout used by bootstrap (both VMs)"
data_disk_device=$(prompt "Data disk device" "$DEF_data_disk_device")
data_partition_device=$(prompt "Data partition device" "$DEF_data_partition_device")
data_mount_point=$(prompt "Data mount point" "$DEF_data_mount_point")
data_disk2_device=$(prompt "Second disk device" "$DEF_data_disk2_device")
data_partition2_device=$(prompt "Second partition device" "$DEF_data_partition2_device")
data_mount2_point=$(prompt "Second mount point" "$DEF_data_mount2_point")

info "Ansible pull (this repo)"
ansible_repo_url=$(prompt "Ansible repo URL (this repo)" "$DEF_ansible_repo_url")
ansible_repo_ref=$(prompt "Ansible repo ref/branch" "$DEF_ansible_repo_ref")
ansible_playbook=$(prompt "Primary playbook path" "$DEF_ansible_playbook")
ansible_playbook_web=$(prompt "Web playbook path" "$DEF_ansible_playbook_web")

info "Web app (ainotebook)"
ainotebook_repo_url=$(prompt "ainotebook repo URL" "$DEF_ainotebook_repo_url")
ainotebook_repo_ref=$(prompt "ainotebook repo ref" "$DEF_ainotebook_repo_ref")
ainotebook_app_dir=$(prompt "ainotebook app dir" "$DEF_ainotebook_app_dir")
ainotebook_streamlit_port=$(prompt "Streamlit port" "$DEF_ainotebook_streamlit_port")
ainotebook_service_name=$(prompt "systemd service name" "$DEF_ainotebook_service_name")

info "Optional: API base for the app (blank -> auto-derive from primary IP)"
api_base=$(prompt "API base" "")

info "Secrets (input is hidden; certs/keys support multi-line via EOF)"
api_key=$(prompt_secret "Cudo API key")
bootstrap_url=$(prompt "Bootstrap URL (public raw URL to terraform/bootstrap.sh)" "${DEF_bootstrap_url:-}")
cf_api_token=$(prompt_secret "Cloudflare API token (optional)" "keep")

read -r -p "Provide ansible deploy SSH key for private repo access? [y/N]: " add_ans_key || true
ansible_repo_ssh_key=""
if [[ "${add_ans_key,,}" == y* ]]; then
  ansible_repo_ssh_key=$(prompt_multiline "Paste private key" "Leave empty to skip; end with EOF")
fi

read -r -p "Provide Cloudflare Origin cert/key PEMs? [y/N]: " add_cf || true
cf_origin_cert_pem=""; cf_origin_key_pem=""
if [[ "${add_cf,,}" == y* ]]; then
  cf_origin_cert_pem=$(prompt_multiline "Paste CF Origin CERT PEM" "end with EOF")
  cf_origin_key_pem=$(prompt_multiline "Paste CF Origin KEY PEM" "end with EOF")
fi

# --- confirm ---
echo
info "Summary"
cat <<CONF
Project:       $project_id
Region:        $data_center_id
Image:         $image_id
Primary VM:    id=$vm_id type=$machine_type vcpus=$vcpus memGiB=$memory_gib bootGiB=$boot_disk_size dataGiB=$storage_disk_size data2GiB=$storage_disk2_size
Web VM:        id=$vm_id_web type=${machine_type_web:-inherit} vcpus=${vcpus_web:-inherit} memGiB=${memory_gib_web:-inherit} bootGiB=${boot_disk_size_web:-inherit} dataGiB=${storage_disk_size_web:-inherit:$storage_disk_size} data2GiB=$storage_disk2_size_web
Disk layout:   $data_disk_device -> $data_partition_device -> $data_mount_point | $data_disk2_device -> $data_partition2_device -> $data_mount2_point
Ansible repo:  $ansible_repo_url ref=$ansible_repo_ref play=$ansible_playbook web_play=$ansible_playbook_web
App repo:      $ainotebook_repo_url ref=$ainotebook_repo_ref dir=$ainotebook_app_dir port=$ainotebook_streamlit_port svc=$ainotebook_service_name
API_BASE:      ${api_base:-"(auto)"}
Bootstrap URL: ${bootstrap_url:-"(unset)"}
Cudo API key:  $(mask "$api_key")
CF API token:  $(mask "$cf_api_token")
SSH key set?:  $([[ -n "$ansible_repo_ssh_key" ]] && echo yes || echo no)
CF cert/key?:  $([[ -n "$cf_origin_cert_pem" || -n "$cf_origin_key_pem" ]] && echo yes || echo no)
CONF

read -r -p "Proceed to write tfvars and run Terraform? [y/N]: " ok || true
if [[ "${ok,,}" != y* ]]; then
  warn "Aborted by user. No changes made."
  exit 1
fi

# --- write files ---
mkdir -p "$TF_DIR"
info "Writing $TFVARS_FILE"
cat > "$TFVARS_FILE" <<TFV
# Generated by scripts/setup.sh
vm_id                 = "$vm_id"
project_id            = "$project_id"
data_center_id        = "$data_center_id"
image_id              = "$image_id"
machine_type          = "$machine_type"
vcpus                 = $vcpus
memory_gib            = $memory_gib
boot_disk_size        = $boot_disk_size
storage_disk_size     = $storage_disk_size
storage_disk2_size    = $storage_disk2_size
ssh_key_source        = "$ssh_key_source"

# Web VM
vm_id_web             = "$vm_id_web"
machine_type_web      = "${machine_type_web}"
vcpus_web             = ${vcpus_web:-0}
memory_gib_web        = ${memory_gib_web:-0}
boot_disk_size_web    = ${boot_disk_size_web:-null}
storage_disk_size_web = ${storage_disk_size_web:-0}
storage_disk2_size_web= ${storage_disk2_size_web:-0}

# Disk layout
data_disk_device       = "$data_disk_device"
data_partition_device  = "$data_partition_device"
data_mount_point       = "$data_mount_point"
# Second disk
data_disk2_device      = "$data_disk2_device"
data_partition2_device = "$data_partition2_device"
data_mount2_point      = "$data_mount2_point"

# ainotebook app
ainotebook_repo_url       = "$ainotebook_repo_url"
ainotebook_repo_ref       = "$ainotebook_repo_ref"
ainotebook_app_dir        = "$ainotebook_app_dir"
ainotebook_streamlit_port = $ainotebook_streamlit_port
ainotebook_service_name   = "$ainotebook_service_name"

# Optional override (else auto-derived)
api_base = "${api_base}"
TFV

info "Writing $SECRETS_FILE (0600)"
{
  echo "# Generated by scripts/setup.sh"
  [[ -n "$api_key" ]] && echo "api_key = \"$api_key\""
  [[ -n "$bootstrap_url" ]] && echo "bootstrap_url = \"$bootstrap_url\""
  [[ -n "$cf_api_token" ]] && echo "cf_api_token = \"$cf_api_token\""
  echo "ansible_repo_url     = \"$ansible_repo_url\""
  echo "ansible_repo_ref     = \"$ansible_repo_ref\""
  echo "ansible_playbook     = \"$ansible_playbook\""
  echo "ansible_playbook_web = \"$ansible_playbook_web\""
  if [[ -n "$ansible_repo_ssh_key" ]]; then
    echo "ansible_repo_ssh_key = <<EOF"
    printf "%s\n" "$ansible_repo_ssh_key"
    echo "EOF"
  fi
  if [[ -n "$cf_origin_cert_pem" ]]; then
    echo "cf_origin_cert_pem = <<EOF"; printf "%s\n" "$cf_origin_cert_pem"; echo "EOF"
  fi
  if [[ -n "$cf_origin_key_pem" ]]; then
    echo "cf_origin_key_pem = <<EOF"; printf "%s\n" "$cf_origin_key_pem"; echo "EOF"
  fi
} > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

# --- run terraform ---
info "Running terraform init/plan/apply in $TF_DIR"
(
  cd "$TF_DIR"
  terraform init
  terraform plan -out plan.out
  terraform apply plan.out
)
