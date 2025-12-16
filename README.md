# OpenNotebook: Terraform + Ansible Deployment

A reproducible, idempotent infrastructure-as-code project for provisioning two VMs on Cudo Compute with Terraform, then configuring them using a unified bootstrap.sh script that behaves differently based on environment variables.

## Executive Summary

- Terraform provisions two VMs on Cudo Compute: **opennotebookserver** (primary) and **opennotebookweb**
- Each VM runs the same `bootstrap.sh` script at first boot, but behavior differs based on environment variables set by Terraform
- **Primary Server (opennotebookserver)**:
  - Installs Docker directly
  - Deploys the OpenNotebook container (`lfnovo/open_notebook:v1-latest-single`) with SurrealDB
  - Exposes API on port 5055 and UI on port 8502
- **Web Server (opennotebookweb)**:
  - Clones the deployment Git repo
  - Runs ansible-playbook to deploy the ainotebook Streamlit application
  - Connects to primary server API via `API_BASE` environment variable
- Secrets never live in the image or Terraform templates: they're passed via variables and dropped to root-only locations on the VM
- The whole flow is idempotent and repeatable

---

## Repository Layout (high level)

- `terraform/` – Infrastructure code for Cudo Compute
  - `cudo_terraform.tf` – Provider and resources (two VMs with boot disks only)
  - `variables.tf` – All TF variables, including deployment configuration
  - `templates/start_script.sh.tpl` – Cloud-init wrapper script that sets environment and runs bootstrap.sh
  - `bootstrap.sh` – The main bootstrap; behavior differs based on ANSIBLE_PLAYBOOK env var
  - `secrets.auto.tfvars` – Local-only secrets and deploy-time values (ignored by Git)
- `ansible/` – Configuration-as-code for the web server deployment
  - `deploy/site.yml` – Placeholder playbook for primary server (currently unused)
  - `deploy/site_web.yml` – Entry-point playbook for web server (deploys ainotebook)
  - `roles/ainotebook/` – Role that deploys the Streamlit application
- `scripts/` – Helper scripts for Terraform setup
  - `setup.sh` – Interactive script to generate secrets.auto.tfvars
- `.gitignore` – Security-focused rules to avoid committing secrets

---

## How Terraform Works Here

Terraform creates:
- Two VM instances booted from Ubuntu 24.04 image:
  - **opennotebookserver** (primary) - Runs OpenNotebook + SurrealDB in Docker
  - **opennotebookweb** - Runs ainotebook Streamlit application
- Each VM has only a boot disk (no separate data disks)
- A first-boot "start script" rendered from `templates/start_script.sh.tpl` and injected via cloud-init

That start script:
1. Sets environment variables that control bootstrap.sh behavior:
   - `ANSIBLE_REPO_URL`, `ANSIBLE_REPO_REF`, `ANSIBLE_PLAYBOOK` - Which playbook to run (if any)
   - `API_BASE` - URL for web server to connect to primary API
   - `AINOTEBOOK_*` - Application-specific configuration
2. Writes SSH deploy key to `/root/.ssh/id_rsa` (root-only, mode 600)
3. Writes optional certificates/keys to `/etc/bootstrap-secrets/` (root-only)
4. Downloads `bootstrap.sh` from a Git URL you control (`bootstrap_url`) and executes it

### Important Variables

Configure these in `terraform/secrets.auto.tfvars` (not committed; it’s ignored):

```hcl
# Cudo provider
api_key        = "<cudo_api_key>"
project_id     = "<cudo_project_id>"
data_center_id = "<region_id>"          # e.g., gb-bournemouth-1
image_id       = "<image_id>"            # e.g., ubuntu-24-04

# Machine type
machine_type   = "intel-broadwell"        # override as desired

# Primary VM sizing (opennotebook)
vcpus          = 4
memory_gib     = 8
boot_disk_size = 50                       # GiB
storage_disk_size  = 20                    # data disk GiB
storage_disk2_size = 0                     # second data disk GiB (0 disables)
ssh_key_source = "user"                   # user | project | custom
vm_id          = "opennotebook"          # human-readable id

# Web VM (opennotebookweb)
vm_id_web          = "opennotebookweb"
# Optional overrides; if omitted, inherits from primary
# machine_type_web     = "intel-broadwell"
# vcpus_web            = 4
# memory_gib_web       = 8
# boot_disk_size_web   = 50
# storage_disk_size_web  = 20
# storage_disk2_size_web = 0

# First-boot
bootstrap_url = "https://raw.githubusercontent.com/<owner>/<repo>/main/terraform/bootstrap.sh"

# Disk layout used by bootstrap (stage 1 & 2)
data_disk_device      = "/dev/sdb"
data_partition_device = "/dev/sdb1"
data_mount_point      = "/opt/apt"
# Second disk mount (optional)
data_disk2_device      = "/dev/sdc"
data_partition2_device = "/dev/sdc1"
data_mount2_point      = "/opt/data2"

# Optional: if your bootstrap or Ansible needs it (example for Cloudflare)
cf_api_token = "<token>"
cf_origin_cert_pem = <<EOF
-----BEGIN CERTIFICATE-----
# (optional PEM)
-----END CERTIFICATE-----
EOF
cf_origin_key_pem = <<EOF
-----BEGIN PRIVATE KEY-----
# (optional PEM)
-----END PRIVATE KEY-----
EOF

# Ansible-pull repo (this repo)
ansible_repo_url     = "git@github.com:<owner>/<repo>.git"   # SSH form for private repo
ansible_repo_ref     = "main"
ansible_playbook     = "ansible/deploy/site.yml"             # primary VM
ansible_playbook_web = "ansible/deploy/site_web.yml"         # web VM

# Web app API endpoint on the primary server
# If left empty, Terraform will auto-derive http://<primary_public_ip>:5055
# after the primary VM is created
api_base = ""

# ainotebook app settings (web VM)
ainotebook_repo_url       = "git@github.com:mightywomble/ainotebook.git"
ainotebook_repo_ref       = "main"
ainotebook_app_dir        = "/opt/ainotebook"
ainotebook_streamlit_port = 8501
ainotebook_service_name   = "ainotebook.service"

# Provide a read-only Deploy Key if the repo is private
# ansible_repo_ssh_key = <<EOF
# -----BEGIN OPENSSH PRIVATE KEY-----
# ...
# -----END OPENSSH PRIVATE KEY-----
# EOF
```

> Why `secrets.auto.tfvars`? Terraform will automatically load it (suffix `.auto.tfvars`) for local values, and this repository's `.gitignore` prevents accidental commits of secrets.

### Specifying the VM(s)

Set `vcpus`, `memory_gib`, `boot_disk_size`, `image_id`, and `data_center_id` to match your desired VM shape and region. The `vm_id` becomes the resource identifier and influences attached disk ids.

If you later scale out to multiple VMs, parameterize and use `for_each` or `count` around the `cudo_vm` resource and the associated disks.

---

## What `bootstrap.sh` Does (Architecture Overview)

`bootstrap.sh` is a unified, version-controlled bootstrap script that runs on **both** VMs but behaves differently based on the `ANSIBLE_PLAYBOOK` environment variable set by Terraform. It's downloaded at first boot from `bootstrap_url` so you can update deployment behavior without rebuilding images or editing long inline scripts in Terraform templates.

### Common Steps (Both VMs)

1. **Logging Setup**: Redirects stdout/stderr to `/root/postinstall.log` for persistence
2. **Environment Validation**: Checks HOME and USER are set (fixes cloud-init issues)
3. **Unattended Upgrades**: Stops and disables to prevent apt lock conflicts during deployment
4. **System Updates**: `apt update && apt upgrade -y`
5. **UFW Firewall**:
   - Allow ports: 80/tcp, 443/tcp, 8501/tcp (Streamlit), 5055/tcp (API), 8502/tcp (UI)
   - Rate-limit SSH: `ufw limit 22/tcp`
   - Enable firewall
6. **SSH Key Setup**: Ensures `/root/.ssh/id_rsa` exists with correct permissions (600)

### Primary Server Only (ANSIBLE_PLAYBOOK="ansible/deploy/site.yml")

**Deployment Method: Direct Docker Installation**

7. **Docker Installation**:
   - Installs Docker Engine via official apt repository
   - Adds Docker GPG key and repository
   - Installs `docker-ce`, `docker-ce-cli`, `containerd.io`
   - Enables and starts Docker service

8. **OpenNotebook Container Deployment**:
   - Pulls `lfnovo/open_notebook:v1-latest-single` image
   - Runs container with:
     - Port mappings: `5055:5055` (API), `8502:8502` (UI)
     - Environment variables:
       - `API_URL=http://<server_ip>:5055`
       - SurrealDB configuration (embedded database)
     - Persistent volumes: `opennotebook-data`, `opennotebook-surreal`
     - Restart policy: `unless-stopped`

**Result**: OpenNotebook API accessible on port 5055, UI on port 8502

### Web Server Only (ANSIBLE_PLAYBOOK="ansible/deploy/site_web.yml")

**Deployment Method: Git Clone + Ansible Playbook**

7. **Ansible Installation**:
   - Installs `ansible-core` and `ansible` via apt
   - Installs `community.general` collection

8. **Repository Clone**:
   - Clones `ANSIBLE_REPO_URL` to `/root/deploy_opennotebook`
   - Checks out `ANSIBLE_REPO_REF` branch
   - Uses SSH key from `/root/.ssh/id_rsa` (auto-detected by Git)

9. **Ansible Playbook Execution**:
   - Runs `ansible-playbook -vvvv` on `site_web.yml`
   - Uses local inventory file
   - Passes extra vars:
     - `api_base` - URL to primary server API
     - `ainotebook_*` - Application configuration
   - Sets `DEBIAN_FRONTEND=noninteractive` to prevent prompts

**Result**: ainotebook Streamlit app running on port 8501 as a systemd service

### Logs

- All output: `/root/postinstall.log`
- Detailed ansible output with `-vvvv` verbosity
- Clear SUCCESS/ERROR markers at the end of bootstrap execution

---

## The Ansible Side

### Expected Layout (example)

```
ansible/
├── deploy/
│   ├── site.yml              # Primary VM entry playbook (currently placeholder)
│   └── site_web.yml          # Web VM entry playbook (invokes ainotebook role)
├── roles/
│   └── ainotebook/
│       ├── defaults/main.yml
│       ├── tasks/main.yml
│       └── templates/ainotebook.service.j2
├── group_vars/
│   └── all.yml               # Optional defaults for all hosts
└── host_vars/
    └── <hostname>.yml
```

### Web VM (opennotebookweb): What Gets Deployed

The `ainotebook` Ansible role deployed via `site_web.yml`:

- **Dependencies**: Installs git, Python3, pip, virtualenv
- **Repository**: Clones `ainotebook_repo_url` to `ainotebook_app_dir` (default: `/opt/ainotebook`)
- **Virtual Environment**: Creates Python venv and installs `requirements.txt`
- **Systemd Service**: Templates `ainotebook.service` that:
  - Runs: `streamlit run app.py --server.port 8501 --server.address 0.0.0.0`
  - Sets `Environment="API_BASE=http://<primary_ip>:5055"` for backend connectivity
  - Runs as dedicated user with working directory in app folder
- **Service Management**: Enables and starts the service with systemd

**Connection Flow**: Web app (port 8501) → API_BASE → Primary server (port 5055) → SurrealDB (embedded)

### Idempotence
- Modules like `apt`, `git`, `pip`, `mount`, `filesystem`, `community.general.parted`, and `systemd` are declarative.
- Re-running ansible-pull will only change what drifted (e.g., new commits in the app repo or updated requirements).
- UFW commands are guarded to avoid duplicate rules.

### Variables You Might Set

- Ports: change UFW rules in your own roles or via vars
- Disk layout: override device and mount point via vars in your repo (by default bootstrap uses `/dev/sdb` to `/opt/apt`)
- Application-specific variables in `group_vars/all.yml` and `host_vars/<hostname>.yml`
- Secrets: use Ansible Vault; `.gitignore` already ignores common vault password files

---

## Prerequisites

You need:
- Git
- Terraform (CLI)
- Access credentials for Cudo Compute (API Key, Project ID)
- A Git repo accessible by the VM for Ansible (SSH deploy key recommended for private repos)

### macOS

```bash
# Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install git terraform
# (Optional) Ansible for local authoring
brew install ansible
```

### Ubuntu Linux

```bash
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release git
# Terraform repository
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update -y && sudo apt-get install -y terraform
# (Optional) Ansible for local authoring
sudo apt-get install -y ansible
```

### Windows

- Recommended: WSL2 with Ubuntu, then follow Ubuntu steps above.
- Native (PowerShell, requires Admin):

```powershell
winget install --id Git.Git -e
winget install --id HashiCorp.Terraform -e
# Optional: winget install --id RedHat.Ansible -e
```

---

## How to Run

1) Clone this repository and configure secrets (do NOT commit them):

```bash
git clone <this-repo>
cd deploy_opennotebook
cp terraform/secrets.auto.tfvars terraform/secrets.auto.tfvars.example # create a sample (optional)
# Edit terraform/secrets.auto.tfvars with your values (see template above)
```

2) Initialize Terraform:

```bash
cd terraform
terraform init
```

3) Plan and Apply:

```bash
terraform plan -out plan.out
terraform apply plan.out
```

Terraform will:
- Create the storage disk and VM
- Inject the start script that fetches and runs `bootstrap.sh`

During first boot, the VMs will:
- Log to `/root/postinstall.log`
- Install Ansible and run early hardening (UFW) + disk partitioning/mount (both VMs)
- Primary VM: pull your Ansible repo and run `ansible/deploy/site.yml`
- Web VM: pull your Ansible repo and run `ansible/deploy/site_web.yml` (deploys the Streamlit app). API_BASE is auto-set to `http://<primary_public_ip>:5055` unless you override `api_base`.

---

## Verifying the Deployment

### Primary Server (opennotebookserver)

SSH to the VM and verify:

```bash
# Check bootstrap log
sudo tail -n 200 /root/postinstall.log

# Verify Docker is running
sudo systemctl status docker
sudo docker ps  # Should show opennotebook container

# Check OpenNotebook logs
sudo docker logs opennotebook

# Verify UFW firewall
sudo ufw status verbose

# Test API endpoint (replace with actual IP)
curl http://localhost:5055/health  # or appropriate endpoint
```

Access the OpenNotebook UI:
- Open browser to `http://<primary_server_ip>:8502`

### Web Server (opennotebookweb)

SSH to the VM and verify:

```bash
# Check bootstrap log
sudo tail -n 200 /root/postinstall.log

# Verify ainotebook service is running
sudo systemctl status ainotebook.service

# Check service logs
sudo journalctl -u ainotebook.service -f

# Verify UFW firewall
sudo ufw status verbose

# Verify cloned repositories
ls -la /root/deploy_opennotebook/
ls -la /opt/ainotebook/
```

Access the Streamlit web app:
- Open browser to `http://<web_server_ip>:8501`

### Re-running Deployments

**Primary Server** (to redeploy OpenNotebook container):
```bash
# Stop and remove existing container
sudo docker stop opennotebook
sudo docker rm opennotebook

# Re-run bootstrap or manually deploy new container
sudo bash /root/postinstall.log  # Contains full bootstrap commands
```

**Web Server** (to update ainotebook app):
```bash
# Navigate to cloned repo
cd /root/deploy_opennotebook

# Update repo
git pull origin main

# Re-run ansible playbook
sudo ansible-playbook -vvvv \
  ansible/deploy/site_web.yml \
  -i ansible/deploy/local.inventory \
  --extra-vars "api_base=http://<primary_ip>:5055" \
  --extra-vars "ainotebook_repo_url=git@github.com:mightywomble/ainotebook.git" \
  --extra-vars "ainotebook_repo_ref=main" \
  --extra-vars "ainotebook_app_dir=/opt/ainotebook" \
  --extra-vars "ainotebook_streamlit_port=8501"
```

---

## Security Considerations

- Secrets are passed via Terraform variables and written only to root-readable paths on the VM (e.g., `/etc/bootstrap-secrets/`).
- `.gitignore` prevents committing common secret files, private keys, and vault artifacts.
- Prefer SSH Deploy Keys for private Git access. Make the key read-only.
- Rotate tokens and keys regularly.

---

## Troubleshooting

### Bootstrap Issues

- **Nothing happens after apply**:
  - Check the Cudo console for VM status and serial/console logs
  - SSH to VM and check: `sudo cat /root/postinstall.log`
  - Verify `bootstrap_url` is reachable: `curl -I <bootstrap_url>`

- **Apt lock conflicts** ("Could not get lock /var/lib/dpkg/lock-frontend"):
  - Bootstrap automatically stops `unattended-upgrades` to prevent this
  - If it still occurs, wait a few minutes for cloud-init to complete, then re-run bootstrap

### Primary Server Issues

- **Docker fails to install**:
  - Check: `sudo apt-cache policy docker-ce`
  - Verify Docker GPG key and repository were added correctly
  - Review: `/root/postinstall.log` for specific error messages

- **OpenNotebook container fails to start**:
  - Check logs: `sudo docker logs opennotebook`
  - Verify image pulled correctly: `sudo docker images | grep open_notebook`
  - Ensure ports 5055 and 8502 are not already in use: `sudo netstat -tlnp | grep -E '5055|8502'`

- **Cannot access OpenNotebook UI**:
  - Verify container is running: `sudo docker ps`
  - Check UFW: `sudo ufw status` (should allow 5055, 8502)
  - Test locally: `curl http://localhost:5055` from the server

### Web Server Issues

- **Ansible fails with Git auth errors**:
  - Ensure `ansible_repo_ssh_key` is set in `secrets.auto.tfvars`
  - Verify SSH key has correct permissions: `ls -la /root/.ssh/id_rsa` (should be 600)
  - Confirm deploy key is added to GitHub repo with read access
  - Test SSH: `ssh -T git@github.com` from the server

- **Ansible playbook fails**:
  - Check full output in `/root/postinstall.log` (includes `-vvvv` verbosity)
  - Verify playbook path exists: `/root/deploy_opennotebook/ansible/deploy/site_web.yml`
  - Manually run playbook to see interactive errors (see "Re-running Deployments" section)

- **ainotebook service fails to start**:
  - Check service status: `sudo systemctl status ainotebook.service`
  - View logs: `sudo journalctl -u ainotebook.service -n 100`
  - Verify Python dependencies: `source /opt/ainotebook/venv/bin/activate && pip list`
  - Check API_BASE connectivity: `curl http://<primary_ip>:5055` from web server

- **Cannot access Streamlit app**:
  - Verify service is running: `sudo systemctl status ainotebook.service`
  - Check UFW: `sudo ufw status` (should allow 8501)
  - Test locally: `curl http://localhost:8501` from the server
  - Verify API_BASE is correct in service environment: `sudo systemctl show ainotebook.service -p Environment`

---

## Destroying Resources

```bash
cd terraform
terraform destroy
```

This will tear down the VM and attached storage created by this module.

---

## License and Contributions

- Contributions welcome via PRs.
- Review `.gitignore` additions carefully before committing any new paths that could include secrets.
