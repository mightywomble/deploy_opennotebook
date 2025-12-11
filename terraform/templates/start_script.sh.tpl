#!/bin/bash
# Minimal wrapper rendered by Terraform to pass sensitive values into the
# first-boot script and fetch the actual bootstrap from a URL to avoid 16KB limits.

set -euo pipefail

# Export token as an environment variable for bootstrap.sh to consume
export CF_API_TOKEN="${cf_api_token}"

# Also write the token to a root-only on-disk location for consumers that expect a file
mkdir -p /etc/bootstrap-secrets
chmod 700 /etc/bootstrap-secrets
printf %s "$CF_API_TOKEN" > /etc/bootstrap-secrets/cf_api_token
chmod 600 /etc/bootstrap-secrets/cf_api_token

# Optionally provision Origin cert and key provided via Terraform variables
# Write to a secure, root-only location that bootstrap.sh will read from.
CERT_SECRET_DIR="/etc/bootstrap-secrets"
mkdir -p "$CERT_SECRET_DIR"
chmod 700 "$CERT_SECRET_DIR"

# Certificate (PEM)
cat > "$CERT_SECRET_DIR/cf_origin_certificate.pem" <<'CERT_PEM'
${cf_origin_cert_pem}
CERT_PEM

# Private key (PEM)
cat > "$CERT_SECRET_DIR/cf_origin_private_key.pem" <<'KEY_PEM'
${cf_origin_key_pem}
KEY_PEM
chmod 600 "$CERT_SECRET_DIR/cf_origin_private_key.pem"

# Ansible repo configuration (for ansible-pull)
export ANSIBLE_REPO_URL="${ansible_repo_url}"
export ANSIBLE_REPO_REF="${ansible_repo_ref}"
export ANSIBLE_PLAYBOOK="${ansible_playbook}"

# Optional app API base for web VM
export API_BASE="${api_base}"

# Optional SSH key for private repo access
if [ -n "${ansible_repo_ssh_key}" ]; then
  install -d -m 700 /root/.ssh
  umask 077
  cat > /root/.ssh/id_ansible <<'ANSIBLE_SSH_KEY'
${ansible_repo_ssh_key}
ANSIBLE_SSH_KEY
  chmod 600 /root/.ssh/id_ansible
  export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ansible -o StrictHostKeyChecking=no"
fi

# Download and execute bootstrap.sh from the provided URL
BOOTSTRAP_TMP="/root/bootstrap.sh"
/usr/bin/curl -fsSL "${bootstrap_url}" -o "$BOOTSTRAP_TMP"
chmod +x "$BOOTSTRAP_TMP"

# Execute
bash "$BOOTSTRAP_TMP"
