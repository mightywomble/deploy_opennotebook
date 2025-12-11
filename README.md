# OpenNotebook: Terraform + Ansible Deployment

A reproducible, idempotent infrastructure-as-code project for provisioning a VM on Cudo Compute with Terraform, then configuring it using Ansible pulled from Git at first boot.

## Executive Summary

- Terraform provisions the VM and a data disk on Cudo Compute and injects a minimal first-boot script.
- The first-boot script fetches a maintained bootstrap.sh from Git, which:
  - Installs Ansible and must-have packages.
  - Runs two local Ansible playbooks for disk setup and system security (UFW) so the host is safe early.
  - Runs ansible-pull to fetch your full configuration from a Git repo (private or public) and apply it (e.g., playbook `ansible/deploy/site.yml`).
- Secrets never live in the image or in Terraform templates: they’re passed via variables and dropped to root-only locations on the VM.
- The whole flow is idempotent and repeatable. You can re-run ansible-pull at any time to converge drift.

---

## Repository Layout (high level)

- `terraform/` – Infrastructure code for Cudo Compute
  - `cudo_terraform.tf` – Provider and resources (VM + storage disk)
  - `variables.tf` – All TF variables, including Ansible-pull configuration
  - `templates/start_script.sh.tpl` – Tiny, rendered first-boot wrapper script
  - `bootstrap.sh` – The main bootstrap; installs Ansible and triggers playbooks
  - `secrets.auto.tfvars` – Local-only secrets and deploy-time values (ignored by Git)
- `ansible/` – Your configuration-as-code, referenced by ansible-pull
  - `deploy/site.yml` – Entry-point playbook executed by ansible-pull
  - `roles/` – Role implementations (handlers, tasks, templates, files, etc.)
  - `group_vars/`, `host_vars/` – Defaults and environment-specific variables
- `.gitignore` – Security-focused rules to avoid committing secrets

> Note: `ansible/` lives in a Git repo that the VM pulls at boot. This repository may be the same one, or you can point Terraform to another repo via variables (recommended for separation of concerns).

---

## How Terraform Works Here

Terraform creates:
- A storage disk (for data)
- A VM instance booted from a specified image
- A first-boot "start script" rendered from `templates/start_script.sh.tpl` and injected via the provider

That start script:
1. Exports sensitive values (tokens, optional deploy SSH key for Git)
2. Writes any provided certificates/keys to `/etc/bootstrap-secrets/` (root-only)
3. Downloads `bootstrap.sh` from a Git URL you control (`bootstrap_url`) and executes it

### Important Variables

Configure these in `terraform/secrets.auto.tfvars` (not committed; it’s ignored):

```hcl
# Cudo provider
api_key        = "<cudo_api_key>"
project_id     = "<cudo_project_id>"
data_center_id = "<region_id>"          # e.g., gb-bournemouth-1
image_id       = "<image_id>"            # e.g., ubuntu-24-04
vcpus          = 4
memory_gib     = 8
boot_disk_size = 50                       # GiB
ssh_key_source = "user"                   # user | project | custom
vm_id          = "opennotebook-vm01"     # human-readable id

# First-boot
bootstrap_url = "https://raw.githubusercontent.com/<owner>/<repo>/main/terraform/bootstrap.sh"

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

# Ansible-pull repo
ansible_repo_url     = "git@github.com:<owner>/<repo>.git"   # SSH form for private repo
ansible_repo_ref     = "main"
ansible_playbook     = "ansible/deploy/site.yml"
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

## What `bootstrap.sh` Does (and Why It’s Pulled From Git)

`bootstrap.sh` is the authoritative, version-controlled bootstrap. It’s downloaded at first boot from `bootstrap_url` so you can update behavior without rebuilding AMIs or editing long inline scripts in Terraform templates.

High-level steps:
1. Logging: Redirects stdout/stderr to `/root/postinstall.log` and console.
2. Installs Ansible and prerequisites; installs the `community.general` collection.
3. Emits and runs two local playbooks:
   - Section 2: System Update & Firewall (apt update/upgrade, UFW allow 80/443, limit 22/tcp)
   - Section 1: Disk Setup (create partition on `/dev/sdb`, format ext4, mount at `/opt/apt`, persist in `/etc/fstab`)
4. Executes `ansible-pull` with repo/branch/playbook from Terraform variables. Clone path: `/root/ansible-src`.
5. Exits with clear SUCCESS/ERROR messages in the log.

> Why ansible-pull? Because the playbooks remain in Git as source of truth, can be private, and are applied on the node, avoiding large cloud-init/user-data limits. Re-running is easy.

Logs:
- Primary: `/root/postinstall.log`
- Ansible output: included in the same log and interactive console during bootstrap

---

## The Ansible Side

### Expected Layout (example)

```
ansible/
├── deploy/
│   └── site.yml              # Entry playbook for ansible-pull
├── roles/
│   ├── common/
│   │   ├── tasks/main.yml
│   │   ├── templates/
│   │   └── files/
│   └── app/
│       ├── tasks/main.yml
│       └── ...
├── group_vars/
│   └── all.yml               # Defaults for all hosts
└── host_vars/
    └── <hostname>.yml
```

### Idempotence

- Modules like `apt`, `ufw`, `mount`, `filesystem`, and `community.general.parted` are declarative.
- Tasks only change when state drifts (e.g., re-partitioning only if missing, mount entries persisted via `mount` module).
- UFW tasks gate on output and use `--force enable` to avoid prompts.

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

During first boot, the VM will:
- Log to `/root/postinstall.log`
- Install Ansible and run early hardening (UFW) + disk partitioning/mount
- Pull your Ansible repo and run `ansible/deploy/site.yml`

---

## Verifying the Deployment

SSH to the VM (from Cudo portal or your SSH key config) and run:

```bash
sudo tail -n 200 /root/postinstall.log
sudo ufw status verbose
lsblk -f | grep -E "sdb|sdb1"
mount | grep "/opt/apt"
```

Re-run your configuration at any time:

```bash
sudo ansible-pull \
  -U "<same repo as TF variable>" \
  -C "<same branch>" \
  -d /root/ansible-src \
  ansible/deploy/site.yml -i "localhost,"
```

---

## Security Considerations

- Secrets are passed via Terraform variables and written only to root-readable paths on the VM (e.g., `/etc/bootstrap-secrets/`).
- `.gitignore` prevents committing common secret files, private keys, and vault artifacts.
- Prefer SSH Deploy Keys for private Git access. Make the key read-only.
- Rotate tokens and keys regularly.

---

## Troubleshooting

- Nothing happens after apply:
  - Check the Cudo console for VM status and serial/console logs
  - Verify the start script rendered correctly (`terraform plan` output) and `bootstrap_url` is reachable
- ansible-pull fails with auth:
  - Ensure `ansible_repo_ssh_key` is set in `secrets.auto.tfvars` and the repo URL uses SSH
  - Confirm Deploy Key is added to the Git repo and allowed to read
- Disk not mounted:
  - Verify the device path is correct (default `/dev/sdb`) and adjust in your repo if needed

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
