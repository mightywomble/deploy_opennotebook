#!/bin/bash

# --- Non-Interactive Idempotent Server Setup Script (Ansible-driven) ---
# This script now installs Ansible and delegates core steps to playbooks.
# Kept: logging, Section 1 (Disk Setup) and Section 2 (System Update & Firewall).
# Removed: Section 3 (apt-mirror), Section 4 (NGINX/Cloudflare), Section 5 (Mirror sync).

set -Eeuo pipefail

# --- Configuration ---
readonly LOG_FILE="/root/postinstall.log"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Disk and Mount Configuration --
readonly DISK_PATH="/dev/sdb"
readonly PARTITION_PATH="/dev/sdb1"
readonly MOUNT_POINT="/opt/apt"

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

    # --- Playbook: Section 1 - Disk Setup ---
    cat > "${PB_DIR}/disk_setup.yml" <<EOF
---
- name: Section 1 - Disk Setup
  hosts: localhost
  connection: local
  become: true
  gather_facts: false
  vars:
    disk_path: "${DISK_PATH}"
    part_path: "${PARTITION_PATH}"
    mount_point: "${MOUNT_POINT}"
  tasks:
    - name: Ensure disk device exists
      ansible.builtin.stat:
        path: "{{ disk_path }}"
      register: disk_stat

    - name: Abort if disk not present
      ansible.builtin.fail:
        msg: "Target disk {{ disk_path }} not found."
      when: not disk_stat.stat.exists

    - name: Ensure disk tools are installed
      ansible.builtin.apt:
        name:
          - parted
          - e2fsprogs
        state: present
        update_cache: false

    - name: Create GPT partition table (idempotent)
      community.general.parted:
        device: "{{ disk_path }}"
        label: gpt
        state: present

    - name: Ensure primary partition exists (1 -> 100%)
      community.general.parted:
        device: "{{ disk_path }}"
        number: 1
        state: present
        part_start: 1MiB
        part_end: 100%

    - name: Create ext4 filesystem on partition
      ansible.builtin.filesystem:
        fstype: ext4
        dev: "{{ part_path }}"
      register: mkfs

    - name: Ensure mount point directory exists
      ansible.builtin.file:
        path: "{{ mount_point }}"
        state: directory
        mode: '0755'

    - name: Mount partition and persist in fstab
      ansible.builtin.mount:
        path: "{{ mount_point }}"
        src: "{{ part_path }}"
        fstype: ext4
        state: mounted
EOF

    # 2) Run playbooks (Section 2, then Section 1 as requested)
    log_action "Running Ansible playbook: system_update_firewall.yml"
    ansible-playbook "${PB_DIR}/system_update_firewall.yml" || log_error_exit "System update/firewall playbook failed."
    log_success "System update & firewall configured."

    log_action "Running Ansible playbook: disk_setup.yml"
    ansible-playbook "${PB_DIR}/disk_setup.yml" || log_error_exit "Disk setup playbook failed."
    log_success "Disk prepared, formatted, mounted, and persisted."

    log_action "--- Script Finished ---"
    log_success "All requested tasks completed via Ansible. Sections 3–5 have been intentionally omitted."
}

# Execute the main function
main
