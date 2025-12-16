#!/bin/bash

# --- Non-Interactive Idempotent Server Setup Script (Ansible-driven) ---
# This script installs Ansible and runs minimal, idempotent configuration.
# Kept: logging and Section 2 (Firewall).
# Removed: Disk setup, apt-mirror, NGINX/Cloudflare, and mirror sync.

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
    echo "DEBIAN_FRONTEND: $DEBIAN_FRONTEND"

    # 0) Install Ansible and prerequisites
    log_action "Installing Ansible and required packages (python3-apt, parted, e2fsprogs, ufw)..."
    apt-get update -qq
apt-get install -y -qq ansible python3-apt ufw || log_error_exit "Failed to install prerequisites."
    log_success "Ansible and prerequisites installed."

    # Ensure required Ansible collections are present (for community.general.parted)
    log_action "Installing required Ansible collections (community.general)..."
    # Some Ansible builds do not support -q; install with --force and log output
    if ! ansible-galaxy collection install community.general --force; then
        # Retry without --force for very old versions
        ansible-galaxy collection install community.general || log_error_exit "Failed to install Ansible collection community.general."
    fi

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

    - name: Ensure UFW is installed
      ansible.builtin.apt:
        name: ufw
        state: present

    - name: Allow SSH with rate limiting
      community.general.ufw:
        rule: limit
        port: "{{ ssh_port }}"
        proto: tcp

    - name: Allow HTTP
      community.general.ufw:
        rule: allow
        port: "80"
        proto: tcp

    - name: Allow HTTPS
      community.general.ufw:
        rule: allow
        port: "443"
        proto: tcp

    - name: Ensure UFW enabled
      community.general.ufw:
        state: enabled

    - name: Ensure UFW service is running and enabled
      ansible.builtin.systemd:
        name: ufw
        state: started
        enabled: true
EOF


    # 2) Run playbooks (Section 2, then Section 1 as requested)
    log_action "Running Ansible playbook: system_update_firewall.yml"
    ansible-playbook -i 'localhost,' "${PB_DIR}/system_update_firewall.yml" || log_error_exit "System update/firewall playbook failed."
    log_success "System update & firewall configured."


    # 3) Pull and run repo playbook if configured
    if [[ -n "${ANSIBLE_REPO_URL:-}" ]]; then
        local REPO_DIR="/root/ansible-src"
        local PLAYBOOK_PATH="${ANSIBLE_PLAYBOOK:-ansible/deploy/site.yml}"
        local PLAYBOOK_BASE
        PLAYBOOK_BASE="$(basename "$PLAYBOOK_PATH")"
        
        log_action "ansible-pull: ${PLAYBOOK_PATH} from ${ANSIBLE_REPO_URL} (ref ${ANSIBLE_REPO_REF:-main})"
        log_action "Detected playbook: ${PLAYBOOK_BASE}"
        
        log_action "=== Environment Variables Check ==="
        echo "ANSIBLE_REPO_URL: ${ANSIBLE_REPO_URL}"
        echo "ANSIBLE_REPO_REF: ${ANSIBLE_REPO_REF:-main}"
        echo "ANSIBLE_PLAYBOOK: ${ANSIBLE_PLAYBOOK}"
        echo "API_BASE: ${API_BASE:-unset}"
        echo "AINOTEBOOK_REPO_URL: ${AINOTEBOOK_REPO_URL:-unset}"
        echo "AINOTEBOOK_REPO_REF: ${AINOTEBOOK_REPO_REF:-unset}"
        echo "AINOTEBOOK_APP_DIR: ${AINOTEBOOK_APP_DIR:-unset}"
        echo "AINOTEBOOK_STREAMLIT_PORT: ${AINOTEBOOK_STREAMLIT_PORT:-unset}"
        echo "AINOTEBOOK_SERVICE_NAME: ${AINOTEBOOK_SERVICE_NAME:-unset}"
        echo "HOME: ${HOME:-unset}"
        echo "USER: ${USER:-unset}"
        echo "GIT_SSH_COMMAND: ${GIT_SSH_COMMAND:-unset}"
        log_action "====================================="

        # Ensure SSH is configured for non-interactive git operations
        install -d -m 700 /root/.ssh || true
        if [ ! -f /root/.ssh/known_hosts ] || ! grep -q github.com /root/.ssh/known_hosts; then
            log_action "Adding GitHub host key..."
            ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null || true
        fi
        
        # Set GIT_SSH_COMMAND for non-interactive git (id_rsa will be used automatically)
        export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"
        log_action "Set GIT_SSH_COMMAND for non-interactive git operations"

        # Clean stale repo directory if it exists but isn't a valid git repo
        if [ -d "${REPO_DIR}" ]; then
            if [ ! -d "${REPO_DIR}/.git" ]; then
                log_action "Removing stale non-git directory: ${REPO_DIR}"
                rm -rf "${REPO_DIR}"
            else
                log_action "Found existing git repo at ${REPO_DIR}"
            fi
        fi

        # Ensure roles path includes both ansible/roles and ansible/deploy/roles
        export ANSIBLE_ROLES_PATH="${REPO_DIR}/ansible/roles:${REPO_DIR}/ansible/deploy/roles:/etc/ansible/roles:/usr/share/ansible/roles"
        log_action "Set ANSIBLE_ROLES_PATH: ${ANSIBLE_ROLES_PATH}"

        # Build extra-vars
        local EVARS="ansible_python_interpreter=/usr/bin/python3"

        # Derive API_BASE intelligently based on playbook
        if [[ -z "${API_BASE:-}" || "${API_BASE}" == *"<"* || "${API_BASE}" == *">"* ]]; then
          if [[ "${PLAYBOOK_BASE}" == "site.yml" ]]; then
            # Primary server: derive from local IP
            local LOCAL_IP
            LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
            if [[ -z "${LOCAL_IP}" ]]; then
              LOCAL_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}')"
            fi
            if [[ -n "${LOCAL_IP}" ]]; then
              API_BASE="http://${LOCAL_IP}:5055"
              log_action "Derived API_BASE for primary: ${API_BASE}"
            fi
          else
            # Web server: API_BASE should be set by Terraform to point to primary
            log_action "Web server detected; API_BASE should be set externally"
          fi
        else
          log_action "Using provided API_BASE: ${API_BASE}"
        fi
        
        if [[ -n "${API_BASE:-}" ]]; then
          EVARS+=" api_base=${API_BASE}"
        fi

        # ainotebook settings (for web VM; harmless on primary)
        if [[ -n "${AINOTEBOOK_REPO_URL:-}" ]]; then EVARS+=" ainotebook_repo_url=${AINOTEBOOK_REPO_URL}"; fi
        if [[ -n "${AINOTEBOOK_REPO_REF:-}" ]]; then EVARS+=" ainotebook_repo_ref=${AINOTEBOOK_REPO_REF}"; fi
        if [[ -n "${AINOTEBOOK_APP_DIR:-}" ]]; then EVARS+=" ainotebook_app_dir=${AINOTEBOOK_APP_DIR}"; fi
        if [[ -n "${AINOTEBOOK_STREAMLIT_PORT:-}" ]]; then EVARS+=" ainotebook_streamlit_port=${AINOTEBOOK_STREAMLIT_PORT}"; fi
        if [[ -n "${AINOTEBOOK_SERVICE_NAME:-}" ]]; then EVARS+=" ainotebook_service_name=${AINOTEBOOK_SERVICE_NAME}"; fi

        # Simple inventory: both playbooks target localhost
        log_action "Creating inventory for ${PLAYBOOK_BASE} (hosts: localhost)"
        local INV_FILE="/root/ansible.inventory"
        cat > "${INV_FILE}" <<'INV'
[all]
localhost ansible_connection=local ansible_host=127.0.0.1
INV

        log_action "Running ansible-pull..."
        log_action "Command: ansible-pull -vv -U ${ANSIBLE_REPO_URL} -C ${ANSIBLE_REPO_REF:-main} -d ${REPO_DIR} ${PLAYBOOK_PATH} -i ${INV_FILE}"
        log_action "Environment check: SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset} HOME=${HOME:-/root} USER=${USER:-root}"
        log_action "GIT_SSH_COMMAND: ${GIT_SSH_COMMAND}"
        
        # Ensure HOME is set for ansible-pull
        export HOME="${HOME:-/root}"
        export USER="${USER:-root}"
        
        # Use -vv for good balance: shows task details and output without massive JSON dumps
        if ansible-pull -vv \
          -U "${ANSIBLE_REPO_URL}" \
          -C "${ANSIBLE_REPO_REF:-main}" \
          -d "${REPO_DIR}" \
          "${PLAYBOOK_PATH}" \
          -i "${INV_FILE}" \
          --extra-vars "${EVARS}"; then
            log_success "ansible-pull completed successfully."
        else
            local exit_code=$?
            log_error_exit "ansible-pull failed with exit code ${exit_code}. Check logs above for details."
        fi
    else
        log_action "ANSIBLE_REPO_URL not set; skipping ansible-pull."
    fi

    log_action "--- Script Finished ---"
    log_success "All requested tasks completed via Ansible. Sections 3–5 have been intentionally omitted."
}

# Execute the main function
main
