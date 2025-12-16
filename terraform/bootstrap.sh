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
# Use simpler redirection that works in cloud-init non-interactive context
exec >> "$LOG_FILE" 2>&1

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


    # 3) Deploy application based on playbook type
    if [[ -n "${ANSIBLE_PLAYBOOK:-}" ]]; then
        local PLAYBOOK_BASE
        PLAYBOOK_BASE="$(basename "${ANSIBLE_PLAYBOOK}")"
        
        if [[ "${PLAYBOOK_BASE}" == "site.yml" ]]; then
            # Primary server: Install Docker and OpenNotebook directly
            log_action "Primary server detected - deploying Docker and OpenNotebook"
            
            # Check if Docker is already installed
            if command -v docker &> /dev/null; then
                log_action "Docker is already installed"
            else
                log_action "Installing Docker..."
                
                # Install prerequisites
                apt-get install -y ca-certificates curl gnupg lsb-release || log_error_exit "Failed to install Docker prerequisites"
                
                # Add Docker's official GPG key
                install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                chmod a+r /etc/apt/keyrings/docker.gpg
                
                # Set up the repository
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
                
                # Install Docker Engine
                apt-get update -qq
                apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || log_error_exit "Failed to install Docker"
                
                # Start and enable Docker
                systemctl enable docker
                systemctl start docker
                
                log_success "Docker installed successfully"
            fi
            
            # Check if OpenNotebook container is already running
            if docker ps --format '{{.Names}}' | grep -q '^opennotebook$'; then
                log_action "OpenNotebook container is already running"
            else
                log_action "Deploying OpenNotebook container..."
                
                # Stop and remove any existing container
                docker stop opennotebook 2>/dev/null || true
                docker rm opennotebook 2>/dev/null || true
                
                # Pull and run OpenNotebook
                docker pull lfnovo/open_notebook:v1-latest-single || log_error_exit "Failed to pull OpenNotebook image"
                
                # Get server IP for API_URL
                local SERVER_IP
                SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
                if [[ -z "${SERVER_IP}" ]]; then
                    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}')"
                fi
                
                docker run -d \
                  --name opennotebook \
                  --restart unless-stopped \
                  -p 5055:5055 \
                  -p 8502:8502 \
                  -e API_URL="http://${SERVER_IP}:5055" \
                  -e SURREAL_URL="ws://localhost:8000/rpc" \
                  -e SURREAL_USER="root" \
                  -e SURREAL_PASSWORD="root" \
                  -e SURREAL_NAMESPACE="open_notebook" \
                  -e SURREAL_DATABASE="production" \
                  -v opennotebook-data:/app/data \
                  -v opennotebook-surreal:/mydata \
                  lfnovo/open_notebook:v1-latest-single || log_error_exit "Failed to start OpenNotebook container"
                
                log_success "OpenNotebook deployed successfully on http://${SERVER_IP}:8502"
            fi
            
            # Show container status
            log_action "Container status:"
            docker ps --filter name=opennotebook --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            
        elif [[ "${PLAYBOOK_BASE}" == "site_web.yml" ]] && [[ -n "${ANSIBLE_REPO_URL:-}" ]]; then
            # Web server: Clone repo and run ansible-playbook
            local REPO_DIR="/root/deploy_opennotebook"
            
            log_action "Web server detected - deploying with git clone + ansible-playbook"
            
            # Ensure SSH is configured
            install -d -m 700 /root/.ssh || true
            if [ ! -f /root/.ssh/known_hosts ] || ! grep -q github.com /root/.ssh/known_hosts; then
                log_action "Adding GitHub host key..."
                ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null || true
            fi
            
            export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"
            export HOME="${HOME:-/root}"
            export USER="${USER:-root}"
            
            # Clone or update repo
            if [ -d "${REPO_DIR}/.git" ]; then
                log_action "Updating existing repository..."
                cd "${REPO_DIR}"
                git fetch origin || log_error_exit "Failed to fetch from remote"
                git checkout "${ANSIBLE_REPO_REF:-main}" || log_error_exit "Failed to checkout ${ANSIBLE_REPO_REF:-main}"
                git pull origin "${ANSIBLE_REPO_REF:-main}" || log_error_exit "Failed to pull latest changes"
            else
                log_action "Cloning repository to ${REPO_DIR}..."
                rm -rf "${REPO_DIR}" 2>/dev/null || true
                git clone "${ANSIBLE_REPO_URL}" "${REPO_DIR}" || log_error_exit "Failed to clone repository"
                cd "${REPO_DIR}"
                git checkout "${ANSIBLE_REPO_REF:-main}" || log_error_exit "Failed to checkout ${ANSIBLE_REPO_REF:-main}"
            fi
            
            log_success "Repository ready at ${REPO_DIR}"
            
            # Build extra-vars for web server
            local EVARS="ansible_python_interpreter=/usr/bin/python3"
            if [[ -n "${API_BASE:-}" ]]; then EVARS+=" api_base=${API_BASE}"; fi
            if [[ -n "${AINOTEBOOK_REPO_URL:-}" ]]; then EVARS+=" ainotebook_repo_url=${AINOTEBOOK_REPO_URL}"; fi
            if [[ -n "${AINOTEBOOK_REPO_REF:-}" ]]; then EVARS+=" ainotebook_repo_ref=${AINOTEBOOK_REPO_REF}"; fi
            if [[ -n "${AINOTEBOOK_APP_DIR:-}" ]]; then EVARS+=" ainotebook_app_dir=${AINOTEBOOK_APP_DIR}"; fi
            if [[ -n "${AINOTEBOOK_STREAMLIT_PORT:-}" ]]; then EVARS+=" ainotebook_streamlit_port=${AINOTEBOOK_STREAMLIT_PORT}"; fi
            if [[ -n "${AINOTEBOOK_SERVICE_NAME:-}" ]]; then EVARS+=" ainotebook_service_name=${AINOTEBOOK_SERVICE_NAME}"; fi
            
            log_action "Environment variables: ${EVARS}"
            
            # Run ansible-playbook
            log_action "Running ansible-playbook..."
            cd "${REPO_DIR}"
            
            set +e
            ansible-playbook -vv \
              -i "localhost," \
              -c local \
              "${ANSIBLE_PLAYBOOK}" \
              --extra-vars "${EVARS}"
            local exit_code=$?
            set -e
            
            if [ $exit_code -eq 0 ]; then
                log_success "ansible-playbook completed successfully."
            else
                log_error_exit "ansible-playbook failed with exit code ${exit_code}."
            fi
        else
            log_action "Unknown playbook: ${PLAYBOOK_BASE}"
        fi
    else
        log_action "ANSIBLE_PLAYBOOK not set; skipping deployment."
    fi

    log_action "--- Script Finished ---"
    log_success "All requested tasks completed via Ansible. Sections 3–5 have been intentionally omitted."
}

# Execute the main function
main
