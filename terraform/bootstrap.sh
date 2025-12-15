#!/bin/bash

# --- Non-Interactive Idempotent Server Setup Script (Ansible-driven) ---
# This script now installs Ansible and delegates core steps to playbooks.
# Kept: logging, Section 1 (Disk Setup) and Section 2 (System Update & Firewall).
# Removed: Section 3 (apt-mirror), Section 4 (NGINX/Cloudflare), Section 5 (Mirror sync).

set -Eeuo pipefail

# Ensure UTF-8 locale for this session and persist system-wide (idempotent)
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANGUAGE="${LANGUAGE:-C.UTF-8}"
if command -v update-locale >/dev/null 2>&1; then
  update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8 || true
fi
mkdir -p /etc/profile.d || true
cat > /etc/profile.d/locale.sh <<'EOF'
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=C.UTF-8
EOF
chmod 0644 /etc/profile.d/locale.sh || true
if [ -f /etc/environment ]; then
  sed -i '/^LANG=/d;/^LC_ALL=/d;/^LANGUAGE=/d' /etc/environment || true
fi
printf '%s\n' 'LANG=C.UTF-8' 'LC_ALL=C.UTF-8' 'LANGUAGE=C.UTF-8' >> /etc/environment || true

# --- Configuration ---
readonly LOG_FILE="/root/postinstall.log"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Disk and Mount Configuration (overridable via environment) --
readonly DISK_PATH="${DISK_PATH:-/dev/sdb}"
readonly PARTITION_PATH="${PARTITION_PATH:-/dev/sdb1}"
readonly MOUNT_POINT="${MOUNT_POINT:-/opt/apt}"

# --- Pre-run Checks & Logging Setup ---
if (( EUID != 0 )); then
   echo "This script must be run as root. Please use 'sudo'."
   exit 1
fi

# Redirect all output (stdout and stderr) to the log file and console
exec &> >(tee -a "$LOG_FILE")

# --- Helper Functions ---
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - INFO: $1"
}

log_success() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] - \e[32mSUCCESS\e[0m: $1"
}

log_error_exit() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] - \e[31mERROR\e[0m: $1" >&2
    exit 1
}

# --- Main Script Logic ---
main() {
    log_action "Starting automated server setup (Ansible-based)."
    export DEBIAN_FRONTEND=noninteractive

    log_action "--- Effective configuration at start ---"
    echo "LOG_FILE: $LOG_FILE"
    echo "SCRIPT_DIR: $SCRIPT_DIR"
    echo "DISK_PATH: $DISK_PATH"
    echo "PARTITION_PATH: $PARTITION_PATH"
    echo "MOUNT_POINT: $MOUNT_POINT"
    echo "DEBIAN_FRONTEND: $DEBIAN_FRONTEND"

    # 0) Install Ansible and prerequisites
    log_action "Installing Ansible and required packages (python3-apt, parted, e2fsprogs, ufw)..."
    apt-get update -qq
apt-get install -y -qq ansible python3-apt parted e2fsprogs ufw || log_error_exit "Failed to install prerequisites."
    log_success "Ansible and prerequisites installed."

    # Ensure required Ansible collections are present (for community.general.parted)
    log_action "Installing required Ansible collections (community.general)..."
    ansible-galaxy collection install community.general --force -q || log_error_exit "Failed to install Ansible collection community.general."

    # 1) Emit playbooks on the target so they can run locally
    local PB_DIR="/root/bootstrap_playbooks"
    mkdir -p "$PB_DIR"

    # --- Playbook: Section 2 - System Update & Firewall ---
    cat > "${PB_DIR}/system_update_firewall.yml" <<EOF
---
- name: Section 2 - System Update & Firewall
  hosts: localhost
  connection: local
  become: true
  gather_facts: false
  vars:
    ssh_port: 22
  tasks:
    - name: Update apt cache and upgrade packages (safe upgrade)
      ansible.builtin.apt:
        update_cache: true
        upgrade: yes
        cache_valid_time: 3600

    - name: Ensure UFW is installed
      ansible.builtin.apt:
        name: ufw
        state: present

    - name: Allow SSH with rate limiting
      ansible.builtin.command: ufw limit {{ ssh_port }}/tcp
      args:
        warn: false
      register: ufw_limit
      changed_when: "'Skipping' not in ufw_limit.stdout"
      failed_when: ufw_limit.rc != 0 and ('Skipping' not in ufw_limit.stdout)

    - name: Allow HTTP
      ansible.builtin.command: ufw allow 80/tcp
      args: { warn: false }
      register: ufw_http
      changed_when: "'Skipping' not in ufw_http.stdout"
      failed_when: ufw_http.rc != 0 and ('Skipping' not in ufw_http.stdout)

    - name: Allow HTTPS
      ansible.builtin.command: ufw allow 443/tcp
      args: { warn: false }
      register: ufw_https
      changed_when: "'Skipping' not in ufw_https.stdout"
      failed_when: ufw_https.rc != 0 and ('Skipping' not in ufw_https.stdout)

    - name: Enable and start UFW
      ansible.builtin.command: ufw --force enable
      args: { warn: false }

    - name: Ensure UFW is enabled at boot and running
      ansible.builtin.systemd:
        name: ufw
        state: started
        enabled: true
EOF

    # --- Playbook: Section 1 - Disk Setup (multi-disk) ---
    cat > "${PB_DIR}/disk_setup.yml" <<'EOF'
---
- name: Section 1 - Disk Setup (multi-disk)
  hosts: localhost
  connection: local
  become: true
  gather_facts: false
  vars:
    default_mount_mode: '0755'
  tasks:
    - name: Build disk list from environment
      ansible.builtin.set_fact:
        disks:
          - disk_path: "{{ lookup('env','DISK_PATH') | default('', true) }}"
            part_path: "{{ lookup('env','PARTITION_PATH') | default('', true) }}"
            mount_point: "{{ lookup('env','MOUNT_POINT') | default('', true) }}"
          - disk_path: "{{ lookup('env','DISK2_PATH') | default('', true) }}"
            part_path: "{{ (lookup('env','PARTITION2_PATH') | default('')) | default((lookup('env','DISK2_PATH') | default('')) ~ '1', true) }}"
            mount_point: "{{ lookup('env','MOUNT2_POINT') | default('/opt/data2', true) }}"

    - name: Filter valid disks (non-empty disk_path)
      ansible.builtin.set_fact:
        disks: "{{ disks | selectattr('disk_path','string') | rejectattr('disk_path','equalto','') | list }}"

    - name: Ensure disk tools are installed
      ansible.builtin.apt:
        name:
          - parted
          - e2fsprogs
        state: present
        update_cache: false

    - name: Process each disk
      ansible.builtin.include_tasks: disk_tasks.yml
      loop: "{{ disks }}"
      loop_control:
        loop_var: d
EOF

    # Per-disk task file used by disk_setup.yml
    cat > "${PB_DIR}/disk_tasks.yml" <<'EOF'
---
- name: Check that disk exists ({{ d.disk_path }})
  ansible.builtin.stat:
    path: "{{ d.disk_path }}"
  register: dev_stat

- name: Skip missing disk
  ansible.builtin.debug:
    msg: "Skipping {{ d.disk_path }} (device not present)"
  when: not dev_stat.stat.exists

- name: Create GPT partition table (idempotent) on {{ d.disk_path }}
  community.general.parted:
    device: "{{ d.disk_path }}"
    label: gpt
    state: present
  when: dev_stat.stat.exists

- name: Ensure primary partition exists (1 -> 100%) on {{ d.disk_path }}
  community.general.parted:
    device: "{{ d.disk_path }}"
    number: 1
    state: present
    part_start: 1MiB
    part_end: 100%
  when: dev_stat.stat.exists

- name: Create ext4 filesystem on {{ d.part_path }}
  ansible.builtin.filesystem:
    fstype: ext4
    dev: "{{ d.part_path }}"
  when: dev_stat.stat.exists

- name: Ensure mount point directory exists ({{ d.mount_point }})
  ansible.builtin.file:
    path: "{{ d.mount_point }}"
    state: directory
    mode: '0755'
  when: dev_stat.stat.exists

- name: Mount partition and persist in fstab ({{ d.mount_point }})
  ansible.builtin.mount:
    path: "{{ d.mount_point }}"
    src: "{{ d.part_path }}"
    fstype: ext4
    state: mounted
  when: dev_stat.stat.exists
EOF

    # 2) Run playbooks (Section 2, then Section 1 as requested)
    log_action "Running Ansible playbook: system_update_firewall.yml"
    ansible-playbook "${PB_DIR}/system_update_firewall.yml" || log_error_exit "System update/firewall playbook failed."
    log_success "System update & firewall configured."

    log_action "Running Ansible playbook: disk_setup.yml (multi-disk)"
    ansible-playbook "${PB_DIR}/disk_setup.yml" || log_error_exit "Disk setup playbook failed."
    log_success "Data disks prepared, formatted, mounted, and persisted."

    # 3) Pull and run repo playbook if configured
    if [[ -n "${ANSIBLE_REPO_URL:-}" ]]; then
        local REPO_DIR="/root/ansible-src"
        log_action "ansible-pull: ${ANSIBLE_PLAYBOOK:-ansible/deploy/site.yml} from ${ANSIBLE_REPO_URL} (ref ${ANSIBLE_REPO_REF:-main})"
        # Build extra-vars string
        local EVARS="ansible_python_interpreter=/usr/bin/python3"
        if [[ -n "${API_BASE:-}" ]]; then
          EVARS="$EVARS api_base=${API_BASE}"
        fi
        # ainotebook settings (for web VM; harmless on primary)
        if [[ -n "${AINOTEBOOK_REPO_URL:-}" ]]; then EVARS="$EVARS ainotebook_repo_url=${AINOTEBOOK_REPO_URL}"; fi
        if [[ -n "${AINOTEBOOK_REPO_REF:-}" ]]; then EVARS="$EVARS ainotebook_repo_ref=${AINOTEBOOK_REPO_REF}"; fi
        if [[ -n "${AINOTEBOOK_APP_DIR:-}" ]]; then EVARS="$EVARS ainotebook_app_dir=${AINOTEBOOK_APP_DIR}"; fi
        if [[ -n "${AINOTEBOOK_STREAMLIT_PORT:-}" ]]; then EVARS="$EVARS ainotebook_streamlit_port=${AINOTEBOOK_STREAMLIT_PORT}"; fi
        if [[ -n "${AINOTEBOOK_SERVICE_NAME:-}" ]]; then EVARS="$EVARS ainotebook_service_name=${AINOTEBOOK_SERVICE_NAME}"; fi
        ansible-pull \
          -U "${ANSIBLE_REPO_URL}" \
          -C "${ANSIBLE_REPO_REF:-main}" \
          -d "${REPO_DIR}" \
          "${ANSIBLE_PLAYBOOK:-ansible/deploy/site.yml}" \
          -i "localhost," \
          --extra-vars "$EVARS" || log_error_exit "ansible-pull failed."
        log_success "ansible-pull completed."
    else
        log_action "ANSIBLE_REPO_URL not set; skipping ansible-pull."
    fi

    log_action "--- Script Finished ---"
    log_success "All requested tasks completed via Ansible. Sections 3–5 have been intentionally omitted."
}

# Execute the main function
main
