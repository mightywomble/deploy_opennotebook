# CUDOS Ubuntu APT Mirror on Cudo (Terraform)

This repository provisions a single VM on Cudo, prepares a 1 TiB data disk for an Ubuntu APT mirror, configures UFW and Nginx, and integrates with Cloudflare for DNS and TLS. It is written to be approachable for absolute beginners while remaining robust and idempotent for repeatable operations.

If you are new to Terraform, start with the quick start. Then read the detailed sections to understand every moving piece, how secrets are handled, and how to verify the deployment end-to-end.

## Table of contents

- [Quick start (beginner-friendly)](#quick-start-beginner-friendly)
- [What this deploys](#what-this-deploys)
- [Repository tour (what each file does)](#repository-tour-what-each-file-does)
- [Recent updates](#recent-updates)
- [Variables and secrets (and how we keep them safe)](#variables-and-secrets-and-how-we-keep-them-safe)
- [Secrets management and 1Password](#secrets-management-and-1password)
- [Cloudflare DNS and certificates](#cloudflare-dns-and-certificates)
- [Why bootstrap.sh is downloaded at boot (16 KB limit)](#why-bootstrapsh-is-downloaded-at-boot-16-kb-limit)
- [Install Terraform (Linux, macOS, Windows)](#install-terraform-linux-macos-windows)
- [Terraform workflow explained](#terraform-workflow-explained)
- [State, plans, and files Terraform creates](#state-plans-and-files-terraform-creates)
- [Run it: commands and what to expect](#run-it-commands-and-what-to-expect)
- [Verify on the server (logs, screen, UFW, Nginx, certs, mounts)](#verify-on-the-server-logs-screen-ufw-nginx-certs-mounts)
- [Idempotence: what it means and why it matters here](#idempotence-what-it-means-and-why-it-matters-here)
- [Listing available images (optional)](#listing-available-images-optional)
- [Troubleshooting](#troubleshooting)

---

## Quick start (beginner-friendly)

Follow these steps. You don’t need prior Terraform experience.

1) Install Terraform
- Linux (Ubuntu/Debian-like): see [Install Terraform](#install-terraform-linux-macos-windows)
- macOS (Homebrew): see [Install Terraform](#install-terraform-linux-macos-windows)
- Windows (winget or Chocolatey): see [Install Terraform](#install-terraform-linux-macos-windows)

2) Get the repository
```bash path=null start=null
git clone https://github.com/mightywomble/terraform_build_repomirror.git
cd terraform_build_repomirror
```

3) Fetch secrets.auto.tfvars from 1Password (or create it)
- We store a pre-filled secrets file in 1Password: “Patching Terraform secrets.auto” in the “service” vault.
- Place the file at the repository root as secrets.auto.tfvars. It is gitignored.
- If you need to create it manually, it should include at least:
```hcl path=null start=null
api_key       = "{{CUDO_API_KEY}}"                  # required for Cudo provider
cf_api_token  = "{{CLOUDFLARE_API_TOKEN}}"         # required for Cloudflare API
bootstrap_url = "https://raw.githubusercontent.com/<org>/<repo>/main/bootstrap.sh"

# Optional but recommended if you already have a Cloudflare Origin cert/key
cf_origin_cert_pem = <<EOF
-----BEGIN CERTIFICATE-----
...your certificate...
-----END CERTIFICATE-----
EOF

cf_origin_key_pem = <<EOF
-----BEGIN PRIVATE KEY-----
...your private key...
-----END PRIVATE KEY-----
EOF
```

4) Set non-secret values in terraform.tfvars
- Open terraform.tfvars and set values like project_id, data_center_id, image_id, vcpus, memory_gib, boot_disk_size, ssh_key_source.
- Example:
```hcl path=null start=null
vm_id            = "cudo-ubuntu-mirror"          # human-friendly identifier for the VM
project_id       = "cudos-public-testnet"
boot_disk_size   = "200"   # GiB
vcpus            = 2
memory_gib       = 4
data_center_id   = "gb-bournemouth-1"
ssh_key_source   = "user"
image_id         = "ubuntu-2404"
```

5) Initialize and validate
```bash path=null start=null
terraform init -upgrade
terraform fmt -recursive
terraform validate
```

6) Plan and apply
```bash path=null start=null
terraform plan --out plan.out
terraform apply plan.out
```

7) After apply: first boot and logs
- The VM boots and runs a tiny wrapper that downloads and executes bootstrap.sh.
- SSH might not be immediately available while the firewall and packages are being configured.
- See [Verify on the server](#verify-on-the-server-logs-screen-ufw-nginx-certs-mounts) for commands to check progress.

---

## What this deploys

- A VM (CPU-only) in the specified Cudo data center, with:
  - 2 vCPUs, 4 GiB RAM (configurable)
  - 200 GiB boot disk (configurable)
  - 1 TiB secondary storage disk for the APT mirror
- A startup process that:
  - Partitions, formats, and mounts /dev/sdb at /opt/apt
  - Installs and configures UFW, Nginx, curl, jq, screen, and apt-mirror
  - Configures apt-mirror to sync Ubuntu 24.04 (noble) repositories
  - Integrates with Cloudflare: creates/updates DNS A record and configures TLS
  - Configures an Nginx site that serves the mirror content over HTTPS
  - Starts apt-mirror in the background via screen (doesn’t block provisioning)

---

## Repository tour (what each file does)

- cudo_terraform.tf
  - Declares the Cudo provider and creates two resources:
- cudo_storage_disk.ubuntu_mirror_storage (1 TiB data disk)
  - Its id is derived from vm_id as "${vm_id}-aptstorage"
- cudo_vm.instance (the VM)
  - Uses start_script to run a tiny wrapper rendered from a template.

- variables.tf
  - Declares all Terraform input variables used in this config, including Cudo settings, Cloudflare settings, and bootstrap_url.

- templates/start_script.sh.tpl
  - A minimal shell script rendered by Terraform on apply. It:
    - Exports CF_API_TOKEN into the environment
    - Writes CF_API_TOKEN and optional cert/key PEMs into /etc/bootstrap-secrets/ (root-only)
    - Downloads bootstrap.sh from bootstrap_url and executes it
  - This keeps the start script tiny and avoids the provider’s 16 KB limit.

- bootstrap.sh
  - The main automation script that runs on the VM. It:
    - Logs a configuration summary (with secrets masked)
    - Prepares and mounts the data disk at /opt/apt
    - Installs UFW, Nginx, curl, jq, screen, apt-mirror
    - Writes /etc/apt/mirror.list for Ubuntu 24.04
    - Resolves public IP, ensures Cloudflare Zone ID, and creates/updates the A record for SUBDOMAIN.DOMAIN
    - Installs a Cloudflare Origin certificate for Nginx from provided PEMs if available; otherwise attempts API creation once
    - Writes an Nginx server config for HTTPS, tests, and reloads Nginx
    - Starts apt-mirror in a screen session
  - The script is designed to be idempotent: safe to re-run without breaking existing setup.

- images_lookup.tf (optional helper)
  - Lets you list available images from the provider (read-only data source). Useful when choosing image_id.

- terraform.tfvars
  - Non-secret values for this environment.

- secrets.auto.tfvars
  - Secret values (gitignored). Terraform auto-loads *.auto.tfvars files.

- .gitignore
  - Ignores Terraform state/local artifacts and local secrets files.

---

## Recent updates

- Added vm_id variable so the VM id is configurable via terraform.tfvars. The 1 TiB storage disk id is now derived from vm_id as "${vm_id}-aptstorage".
- Removed unused cudo_platform variable and all references from code and docs.

## Variables and secrets (and how we keep them safe)

Key variables
- api_key (sensitive): Cudo API key for the provider.
- project_id, data_center_id, image_id, vcpus, memory_gib, boot_disk_size, ssh_key_source: VM configuration.
- cf_api_token (sensitive): Cloudflare API token used by bootstrap.sh.
- bootstrap_url: Public URL where the VM can download bootstrap.sh on first boot.
- cf_origin_cert_pem, cf_origin_key_pem (sensitive, optional): Provide these if you already have a Cloudflare Origin certificate and private key; the VM will install them and skip API creation.

Where secrets live
- Locally: secrets.auto.tfvars at the repo root.
  - This file is ignored by Git and should never be committed.
- On the VM (at boot): the wrapper writes secrets to /etc/bootstrap-secrets/ with root-only permissions.
  - CF token: /etc/bootstrap-secrets/cf_api_token
  - Origin cert/key (if provided): /etc/bootstrap-secrets/cf_origin_certificate.pem and ..._private_key.pem
- bootstrap.sh loads CF_API_TOKEN from env or from these files and logs only a masked preview, never the full value.

Why this matters
- Cloud API keys and TLS private keys grant powerful access. Leaking them can compromise infrastructure and traffic.
- By keeping secrets out of Git, out of the command history, and only on the VM with strict permissions, we reduce risk.

---

## Secrets management and 1Password

- We maintain a 1Password entry named “Patching Terraform secrets.auto” in the “service” vault.
- Use it to retrieve or patch your local secrets.auto.tfvars.
- Place secrets.auto.tfvars in the repository root. Terraform will auto-load it.
- Never commit secrets. If a secret is ever exposed, rotate/revoke it immediately.

---

## Cloudflare DNS and certificates

- DNS A record: bootstrap.sh fetches your public IP and:
  - Looks up the Zone ID for DOMAIN via the Cloudflare API
  - Creates or updates the A record for SUBDOMAIN.DOMAIN (proxied = true)
- Origin certificate for Nginx TLS:
  - Preferred: provide cf_origin_cert_pem and cf_origin_key_pem in secrets.auto.tfvars. The VM installs them to /etc/nginx/ssl and skips the API call.
  - If not provided but the files already exist on the VM, it reuses them.
  - Otherwise, it attempts to create a new origin cert via the Cloudflare API. Note: the private key is only returned on creation and cannot be retrieved later.
- The script also sets Cloudflare’s SSL/TLS mode to “Full (Strict)” for the zone (best effort).

---

## Why bootstrap.sh is downloaded at boot (16 KB limit)

Some providers enforce a small size on the start_script. To keep things maintainable and pass larger logic:
- We render a tiny wrapper as the start_script (templates/start_script.sh.tpl)
- The wrapper exports secrets, writes PEMs, and downloads bootstrap.sh from bootstrap_url
- This avoids size limits and keeps your logic centralized in bootstrap.sh under version control

---

## Install Terraform (Linux, macOS, Windows)

Linux (Ubuntu/Debian)
```bash path=null start=null
sudo apt-get update -y
sudo apt-get install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update -y
sudo apt-get install -y terraform
terraform -version
```

macOS (Homebrew)
```bash path=null start=null
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform -version
```

Windows
```powershell path=null start=null
# winget (Windows 10/11)
winget install HashiCorp.Terraform

# or Chocolatey
choco install terraform -y

terraform -version
```

---

## Terraform workflow explained

- terraform init: downloads providers and sets up the working directory. Run after cloning or when providers change.
- terraform fmt -recursive: formats .tf files for readability.
- terraform validate: checks config syntax and catches many common mistakes.
- terraform plan --out plan.out: produces a precise execution plan and writes it to plan.out.
- terraform apply plan.out: applies exactly what you reviewed in plan.out.
- terraform destroy: tears down resources created by the current configuration (use with care).
- terraform state list/show: inspects what is currently tracked in state and its attributes.

Tip: Always create and apply from a saved plan (plan.out) so what you execute is exactly what you reviewed.

---

## State, plans, and files Terraform creates

- terraform.tfstate and terraform.tfstate.backup
  - The real-time record of what was created and its attributes. Contains sensitive data; treat as secret.
  - In this repo, state is local (not remote). Do not commit these files.
- .terraform/ directory
  - Provider plugins and modules cache. Do not commit.
- .terraform.lock.hcl
  - Provider dependency locks. In this project it’s gitignored; many teams commit it. We follow the project’s current ignore rules.
- plan.out
  - A binary plan produced by terraform plan --out. You can keep it locally for the immediate apply; it’s not meant to be committed.

Our .gitignore is configured to keep all these out of version control, along with your secrets files.

---

## Run it: commands and what to expect

1) Prepare
```bash path=null start=null
terraform init -upgrade
terraform fmt -recursive
terraform validate
```

2) Plan and apply
```bash path=null start=null
terraform plan --out plan.out
terraform apply plan.out
```

3) Getting the VM’s IP
- Use the Cudo portal, or inspect state:
```bash path=null start=null
terraform state show cudo_vm.instance | sed -n '1,200p'
```
- Look for network/addresses fields provided by the provider.

4) First SSH attempt
- SSH may be blocked briefly while UFW is configured. Try again after a minute or two.
- If you see a host key mismatch (reused IP), clear the old known_hosts entry:
```bash path=null start=null
ssh-keygen -R <VM_PUBLIC_IP>
```

---

## Verify on the server (logs, screen, UFW, Nginx, certs, mounts)

SSH to the VM when it’s ready.

Logs and config summary
```bash path=null start=null
sudo tail -n 200 /root/postinstall.log
```
- Near the top you’ll see lines like NAME: value; secrets are masked. You should see:
  - CF_API_TOKEN: abcd****wxyz
  - CF_API_TOKEN_SOURCE: /etc/bootstrap-secrets/cf_api_token

apt-mirror background job (screen)
```bash path=null start=null
screen -ls            # should show a session named "aptmirror"
screen -r aptmirror   # attach; Ctrl+A then D to detach
```

Disk and mount
```bash path=null start=null
df -h | grep /opt/apt
ls -l /opt/apt
```

UFW
```bash path=null start=null
sudo ufw status numbered
```

Nginx
```bash path=null start=null
sudo nginx -t
sudo systemctl status nginx --no-pager
ls -l /etc/nginx/ssl
```
- Expect to see ${SUBDOMAIN}.${DOMAIN}.pem and .key present.
- Test HTTPS locally on the VM:
```bash path=null start=null
curl -Ik https://<SUBDOMAIN>.<DOMAIN>/
```

Cloudflare DNS
- The A record for <SUBDOMAIN>.<DOMAIN> should exist and be proxied. Check the Cloudflare dashboard.

Reboot safety
- After a reboot, the mount, UFW rules, certificates, and Nginx config should persist. The design is idempotent (see next section).

---

## Idempotence: what it means and why it matters here

Idempotence means you can run the same script multiple times and, after the first successful run, nothing breaks or regresses. Only missing bits are added; existing correct settings are left alone.

bootstrap.sh uses checks before actions, for example:
- Disk: only partitions/formats/mounts if needed, and writes /etc/fstab for persistence.
- UFW: installs/enables and opens the required ports if not already configured.
- apt-mirror: writes the config if needed and launches a background sync; re-runs don’t spawn duplicates.
- Cloudflare DNS: creates the A record if missing; updates it only if the IP changed.
- TLS: if cert/key files exist on disk, reuse them; otherwise install from Terraform-provided PEMs; only if neither exists does it attempt API creation.
- Nginx: writes the site config, tests it, and reloads; subsequent runs won’t duplicate.

Idempotence is crucial for safe re-runs after partial failures, for upgrades, and for predictable recoveries.

---

## Listing available images (optional)

We include a helper to list VM images exposed by the provider.
```bash path=null start=null
terraform apply -target=data.cudo_vm_images.available -auto-approve
terraform output -json available_images | jq -r '.[] | "\(.id)\t\(.name)\t\(.description)"' | head -n 50
```
Pick the image_id you want (e.g., ubuntu-2404) and set it in terraform.tfvars.

---

## Troubleshooting

- start_script too large: We already solved this by downloading bootstrap.sh at boot.
- CF_API_TOKEN not set: Make sure secrets.auto.tfvars includes cf_api_token and that bootstrap_url is reachable. The log shows CF_API_TOKEN_SOURCE when loaded.
- Origin certificate creation failed: If a cert already exists in Cloudflare, the API won’t return its private key. Either provide cf_origin_cert_pem/key via secrets.auto.tfvars, or revoke and recreate.
- SSH errors or timeouts: UFW may block briefly; retry. For host key mismatch: ssh-keygen -R <IP>.
- Nothing seems to happen: tail -f /root/postinstall.log and check for errors. Verify network access to bootstrap_url and to Cloudflare APIs.
- apt-mirror takes hours: That’s expected on first sync. Use screen -r aptmirror to watch progress.

---

## Quick start (for beginners)

Follow these steps exactly. No prior Terraform experience required.

1) Get your Cudo API key
- In the Cudo portal, create or locate an API key with access to your project. Keep it secret.

2) Put your API key in the right file (do NOT commit it)
- In this repository's root directory, create a file named exactly: secrets.auto.tfvars
- Put this content in it (replace with your real key):

```hcl
api_key = "{{YOUR_CUDO_API_KEY}}"
```

Notes:
- The filename must be secrets.auto.tfvars (Terraform auto-loads it).
- This file is gitignored so it will not be committed.

3) Set your project_id and other values
- Open terraform.tfvars and set:
  - project_id = "your Cudo Compute project name"
  - image_id = "ubuntu-2404" (recommended)
  - data_center_id = "gb-bournemouth-1" (or your chosen data center)
  - vcpus, memory_gib, boot_disk_size, ssh_key_source as desired

4) Initialize and validate
```bash
terraform init
terraform fmt -recursive
terraform validate
```

5) Plan and apply
```bash
terraform plan --out plan.out
terraform apply plan.out
```

6) What happens next (bootstrap.sh)
- On first boot the VM runs a tiny wrapper that:
  - Exports `CF_API_TOKEN`
  - Writes optional `cf_origin_cert_pem` and `cf_origin_key_pem` into `/etc/bootstrap-secrets/`
  - Downloads `bootstrap.sh` from `bootstrap_url` and executes it
- Then `bootstrap.sh`:
  - Partitions and mounts /dev/sdb at /opt/apt
  - Updates the system and configures the firewall (UFW)
  - Installs apt-mirror and writes /etc/apt/mirror.list for Ubuntu 24.04 (noble)
  - Configures Cloudflare DNS for `${SUBDOMAIN}.${DOMAIN}`
  - Installs a Cloudflare Origin certificate for Nginx from provided PEMs or (if absent) creates one via API
  - Starts a one-time apt-mirror run in the background using screen (session name: aptmirror)
- This may take several hours to complete; Terraform will not wait for it.

7) How to check progress and logs
- Log into the VM, then:
  - View bootstrap logs (errors will appear here):
    - tail -f /root/postinstall.log
    - At the top you’ll see a configuration summary in `name: value` format; secrets are masked. Ensure `CF_API_TOKEN` is shown masked and that `CF_API_TOKEN_SOURCE` points to `/etc/bootstrap-secrets/cf_api_token`.
  - Check the screen session running apt-mirror:
    - screen -ls
    - screen -r aptmirror   # attach; press Ctrl+A then D to detach
  - Check disk/mount:
    - df -h | grep /opt/apt
    - ls -ltr /opt/apt/var /opt/apt/mirror

---

## Prerequisites

- An Ubuntu Linux workstation machine (Ubuntu-based). Commands below use bash.
- A Cudo API key with access to your project.
- Git installed.
- SSH keys available in your Cudo account (we use `ssh_key_source = "user"`).

Important: Never commit secrets to Git. Use environment variables or a local, ignored `terraform.tfvars` file.

---

## Install Terraform (Linux Mint / Ubuntu)

Use HashiCorp's official apt repository.

```bash path=null start=null
# 1) Install required packages
sudo apt-get update -y
sudo apt-get install -y gnupg software-properties-common curl

# 2) Add HashiCorp's GPG key and repo
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

# 3) Install terraform
sudo apt-get update -y
sudo apt-get install -y terraform

# Verify
terraform -version
```

---

## Repository layout

- `cudo_terraform.tf` — Main Terraform configuration:
  - Declares the Cudo provider and version
  - Creates a 1 TiB storage disk resource
  - Creates the VM resource and attaches the storage disk
  - References variables like `var.api_key`, `var.project_id`, `var.data_center_id`, etc.
- `bootstrap.sh` — Startup script that runs on the VM's first boot. It prepares the extra disk, configures the firewall, writes apt-mirror config, configures Nginx, manages Cloudflare DNS and origin certificates, and launches a one-time apt-mirror sync in the background (via screen) so Terraform is not blocked.
- `templates/start_script.sh.tpl` — A tiny wrapper rendered by Terraform that:
  - Exports `CF_API_TOKEN`
  - Writes optional certificate PEMs provided via Terraform to `/etc/bootstrap-secrets/`
  - Downloads `bootstrap.sh` from `var.bootstrap_url` and executes it. This avoids the provider’s 16 KB `start_script` size limit.
- `variables.tf` — Variable declarations for all inputs used by the config (including Cloudflare-related variables and `bootstrap_url`).
- `terraform.tfvars` — Non-secret variable values for this environment (example values). You may override locally or via environment variables.
- `secrets.auto.tfvars` — Secret values (gitignored by default). Never commit secrets.
- `images_lookup.tf` — Temporary helper to list available images from the provider (optional; safe to remove after use).
- `.gitignore` — Ensures local state and secret tfvars are ignored.

Tip: For GitHub/public use, keep secrets out of version control. Prefer environment variables or a local `secrets.auto.tfvars` in `.gitignore`.

### Recent changes

- Introduced a secure, extensible secrets flow using `secrets.auto.tfvars` (gitignored) and sensitive Terraform variables.
- Added a minimal `start_script` wrapper that downloads `bootstrap.sh` from `var.bootstrap_url` to avoid the 16 KB provider limit, while safely injecting secrets (Cloudflare token and optional PEM cert/key).
- `bootstrap.sh` now:
  - Logs effective configuration (with secrets masked) at startup for easy verification
  - Loads `CF_API_TOKEN` from environment or from safe on-VM paths
  - Installs Cloudflare origin cert/key from Terraform-provided PEMs if present; otherwise attempts API creation; remains idempotent if files already exist
- `.gitignore` updated to ignore secrets tfvars files and local `.env` files.
- Variables expanded: `cf_api_token`, `bootstrap_url`, `cf_origin_cert_pem`, `cf_origin_key_pem`.
- Corrected image handling and examples — use `image_id = "ubuntu-2404"` for Ubuntu 24.04.
- Added `images_lookup.tf` and instructions to list available images via the provider data source.

---

## How variables are provided and used

This configuration expects the following inputs (among others):
- `api_key` (string, sensitive): Your Cudo API key
- `project_id` (string): Your Cudo Compute project name (exactly as it appears in Cudo)
- `data_center_id` (string): Data center (e.g., `gb-bournemouth-1`)
- `image_id` (string): OS image identifier (e.g., `ubuntu-2404`)
- `vcpus` (number): CPU count (currently 2)
- `memory_gib` (number): RAM in GiB (currently 4)
- `boot_disk_size` (number or string): Boot disk size in GiB (200)
- `ssh_key_source` (string): Where to pull SSH keys from (`user` or `project` or `custom`)
- `cf_api_token` (string, sensitive): Cloudflare API token used by `bootstrap.sh`
- `bootstrap_url` (string): URL from which the VM downloads `bootstrap.sh` on first boot
- `cf_origin_cert_pem` (string, sensitive): Optional PEM for a pre-created Cloudflare Origin certificate
- `cf_origin_key_pem` (string, sensitive): Optional PEM for the corresponding private key

The values flow like this:
- You supply values via environment variables (recommended) or `terraform.tfvars` + `secrets.auto.tfvars`.
- The `start_script` wrapper (rendered from `templates/start_script.sh.tpl`) exports tokens and writes PEMs to `/etc/bootstrap-secrets/`, then downloads and runs `bootstrap.sh`.
- `bootstrap.sh` consumes those values, logs masked configuration, and proceeds idempotently.

### Option A: Use environment variables (recommended for secrets)

```bash path=null start=null
# Do NOT print your secret to the terminal.
# Store it as an environment variable for Terraform to pick up.
export TF_VAR_api_key={{CUDO_API_KEY}}

# Non-secret values can also be provided via env vars (optional):
export TF_VAR_project_id=cudos-public-testnet
export TF_VAR_data_center_id=gb-bournemouth-1
export TF_VAR_image_id=ubuntu-2404
export TF_VAR_vcpus=2
export TF_VAR_memory_gib=4
export TF_VAR_boot_disk_size=200
export TF_VAR_ssh_key_source=user
```

### Option B: Use local tfvars files (never commit secrets)

We recommend splitting secrets into a separate file which is ignored by Git.

1) Create `terraform.tfvars` (checked in; no secrets) with only non-secret values:

```hcl path=null start=null
# terraform.tfvars (checked in; no secrets)
project_id       = "cudos-public-testnet"
cudo_platform    = "public-testnet"
boot_disk_size   = "200"
vcpus            = 2
memory_gib       = 4
data_center_id   = "gb-bournemouth-1"
ssh_key_source   = "user"
image_id         = "ubuntu-2404"
```

2) Create `secrets.auto.tfvars` (gitignored) with your secrets. You can fetch the pre-filled values from 1Password: look for the item “Patching Terraform secrets.auto” under the “service” vault.

```hcl path=null start=null
# secrets.auto.tfvars (ignored by Git)
api_key       = "{{CUDO_API_KEY}}"
cf_api_token  = "{{CLOUDFLARE_API_TOKEN}}"
bootstrap_url = "https://raw.githubusercontent.com/<org>/<repo>/main/bootstrap.sh"

# Optional: provide origin cert/key PEMs to avoid creating via API at boot
cf_origin_cert_pem = <<EOF
-----BEGIN CERTIFICATE-----
...your certificate...
-----END CERTIFICATE-----
EOF

cf_origin_key_pem = <<EOF
-----BEGIN PRIVATE KEY-----
...your private key...
-----END PRIVATE KEY-----
EOF
```

Important:
- This file is required to provide `api_key` and is the recommended place to supply `cf_api_token` and `bootstrap_url`.
- It is intentionally gitignored. If it was previously committed, revoke/rotate the secrets.
- Never print or commit the actual secrets. Consider using 1Password to store and patch this file.

Terraform automatically loads any `*.auto.tfvars` files in the working directory, so you don't need to pass `-var-file` flags.

### If you need variable declarations (variables.tf)

If your `variables.tf` is not available or is encrypted, you can create a simple one like this so Terraform knows the variables' names and types:

```hcl path=null start=null
variable "api_key" {}
variable "project_id" {}
variable "data_center_id" {}
variable "image_id" {}
variable "vcpus" { type = number }
variable "memory_gib" { type = number }
variable "boot_disk_size" {}
variable "ssh_key_source" {}
```

---
# Running Terraform, what is going on..

Think of building infrastructure with Terraform like assembling a complex piece of furniture. You need to follow a clear set of steps to ensure it's built correctly and exactly as the instructions intended. These commands are those steps.

## Initialization & Validation
First, you need to prepare your workspace and check your instructions.

terraform init: This is the very first command you run in a new Terraform project. It's like opening the furniture box and laying out all the tools and parts. This command downloads the necessary plugins (called providers) that allow Terraform to communicate with your cloud provider (like AWS, Azure, or Google Cloud). It only needs to be run once at the beginning or whenever you add a new provider.

terraform fmt -recursive & terraform validate: These are your quality checks. The fmt command tidies up your code, making it neat and easy to read, which is helpful when working in a team. The validate command runs a quick check for any syntax errors or typos in your configuration files. Think of this as proofreading the instruction manual to make sure it's written correctly before you start building.

## Planning & Applying Changes
Next, you create a blueprint of what you're going to build and then execute that plan.

terraform plan --out plan.out: This is arguably the most important command. It creates an execution plan, which is a detailed preview of exactly what Terraform will do. It will show you which resources it will create, change, or destroy without actually making any changes. By using the --out plan.out flag, you save this exact plan to a file. This is like getting a final, itemized quote from a contractor before they start work, ensuring there are no surprises.

terraform apply plan.out: This command executes the plan you just saved. It takes the plan.out file and builds the infrastructure exactly as described in it. By applying a saved plan, you guarantee that the actions Terraform takes are the same ones you reviewed and approved, preventing any accidental changes. This is the "build" step where the furniture is actually assembled according to the blueprint.

## Verifying the Result
Finally, after the work is done, you inspect the final product.

terraform state list & terraform show: These commands let you see what you've built. terraform state list gives you a simple inventory of all the resources Terraform is currently managing. For a more detailed view, terraform show displays all the attributes of those resources, such as their IP addresses, IDs, and other settings. This is your way of looking at the finished piece of furniture and confirming all the parts are in the right place and it matches the design.

## What this Terraform code does

- Creates a storage disk resource of 1024 GiB in `gb-bournemouth-1`.
- Creates a VM resource named `cudo-ubuntu-mirror`:
  - CPU-only machine type (e.g., `intel-broadwell`)
  - 2 vCPUs, 4 GiB RAM
  - 200 GiB boot disk from `var.image_id` (e.g., `ubuntu-2404`)
  - Attaches the 1 TiB storage disk to the VM
- Uses your SSH keys (according to `ssh_key_source`) so you can log in after provisioning.

---

## Initialize, plan, and apply

Run all commands from the repository root (same directory as `cudo_terraform.tf`). Ensure your `secrets.auto.tfvars` is present (from 1Password if applicable) and that `bootstrap_url` is reachable from the VM.

```bash
# Initialize providers and modules
terraform init

# Optional but recommended: format and validate
terraform fmt -recursive
terraform validate

# Create a plan and save it to a file
terraform plan --out plan.out
# Note: *.auto.tfvars (e.g., secrets.auto.tfvars) are auto-loaded; explicit -var-file flags are usually unnecessary.

# Apply exactly what was planned ("terraform run" is not a Terraform command)
terraform apply plan.out
# Or with explicit var files (if not using auto.tfvars):
# terraform apply -var-file=terraform.tfvars -var-file=secrets.auto.tfvars plan.out
```

## Quick start (for beginners)

Follow these steps exactly. No prior Terraform experience required.

1) Get your Cudo API key
- In the Cudo portal, create or locate an API key with access to your project. Keep it secret.

2) Put your API key in the right file (do NOT commit it)
- In this repository's root directory, create a file named exactly: secrets.auto.tfvars
- Put this content in it (replace with your real key):

```hcl path=null start=null
api_key = "{{YOUR_CUDO_API_KEY}}"
```

Notes:
- The filename must be secrets.auto.tfvars (Terraform auto-loads it).
- This file is gitignored so it will not be committed.

3) Set your project_id and other values
- Open terraform.tfvars and set:
  - project_id = "<your Cudo Compute project name>"
  - image_id = "ubuntu-2404" (recommended)
  - data_center_id = "gb-bournemouth-1" (or your chosen data center)
  - vcpus, memory_gib, boot_disk_size, ssh_key_source as desired

4) Initialize and validate
```bash path=null start=null
terraform init
terraform fmt -recursive
terraform validate
```

5) Plan and apply
```bash path=null start=null
terraform plan --out plan.out
terraform apply plan.out
```

6) What happens next (bootstrap.sh)
- On first boot the VM runs bootstrap.sh, which:
  - Partitions and mounts /dev/sdb at /opt/apt
  - Updates the system and configures the firewall (UFW)
  - Installs apt-mirror and writes /etc/apt/mirror.list for Ubuntu 24.04 (noble)
  - Starts a one-time apt-mirror run in the background using screen (session name: aptmirror)
- This may take several hours to complete; Terraform will not wait for it.

7) How to check progress and logs
- Log into the VM, then:
  - View bootstrap logs (errors will appear here):
    - tail -f /root/postinstall.log
  - Check the screen session running apt-mirror:
    - screen -ls
    - screen -r aptmirror   # attach; press Ctrl+A then D to detach
  - Check disk/mount:
    - df -h | grep /opt/apt
    - ls -ltr /opt/apt/var /opt/apt/mirror

---

## Secrets management and 1Password

- Secrets live in `secrets.auto.tfvars` which is ignored by Git.
- We maintain a 1Password entry named “Patching Terraform secrets.auto” under the “service” vault. Use it to patch or regenerate your local `secrets.auto.tfvars` quickly and safely.
- Do not paste secrets on the command line; if you need to use environment variables, set them without echoing the values.

## Cloudflare DNS and certificates

- Cloudflare API token (`cf_api_token`) is provided via Terraform and exported to the VM at boot.
- DNS handling is idempotent: the script creates or updates the A record for `${SUBDOMAIN}.${DOMAIN}`.
- Certificates:
  - If `cf_origin_cert_pem` and `cf_origin_key_pem` are provided, the wrapper writes them to `/etc/bootstrap-secrets/` and `bootstrap.sh` installs them to `/etc/nginx/ssl/`.
  - If they are not provided but the cert/key already exist on disk, the script skips creation.
  - Otherwise, the script attempts to create a new Cloudflare Origin Certificate via API. Note: the private key is only available at creation time.

## Why we download bootstrap.sh (16KB limit)

Some providers enforce a small size limit on the `start_script` field. To work around this safely:
- We render a tiny wrapper (`templates/start_script.sh.tpl`) as the start script.
- The wrapper exports secrets, writes optional PEMs, and downloads `bootstrap.sh` from `bootstrap_url`.
- This keeps the start script tiny and your logic centralized in `bootstrap.sh`.

## Listing available images

We provide `images_lookup.tf` to list the image IDs exposed by the provider. This does not create any infrastructure; it only reads data.

```bash path=null start=null
# Query the images data source and print the first 50 entries
terraform apply -target=data.cudo_vm_images.available -auto-approve
terraform output -json available_images | jq -r '.[] | "\(.id)\t\(.name)\t\(.description)"' | head -n 50
```

- Pick the desired image ID (e.g., `ubuntu-2404`) and set `image_id` accordingly.
- Optional cleanup: delete `images_lookup.tf` once done and run `terraform plan` to ensure no pending changes.

### Verifying the deployment

```bash path=null start=null
# List resources in state
terraform state list

# Show detailed state, including attributes like IP addresses
terraform show
```

You can also verify the VM and disk in the Cudo portal.

---

## Making changes later

- Edit values in your environment variables or `terraform.tfvars` (e.g., RAM, boot disk size, image, data center).
- Run `terraform plan` to see proposed changes, then `terraform apply` to make them.

---

## Destroying the resources

When you're done and want to clean up:

```bash path=null start=null
cd cudo
terraform destroy
```

Terraform will prompt you for confirmation and then tear down the resources it created.

---

## Debugging and troubleshooting

- Syntax issues: run `terraform validate` to catch common mistakes.
- Provider/auth errors (e.g., 401/403): ensure `TF_VAR_api_key` is set and correct, and that your project ID is valid.
- Invalid IDs: double-check `data_center_id` (e.g., `gb-bournemouth-1`) and `image_id` (e.g., `ubuntu-2404`).
- VM bootstrap logs: check /root/postinstall.log (created by bootstrap.sh) for any setup errors.
- apt-mirror run: use screen -ls and screen -r aptmirror to view the ongoing mirror sync; it can take hours.
- Plan/apply errors: re-run with logging enabled to capture more detail.

Enable logs:
```bash path=null start=null
# Options: TRACE, DEBUG, INFO, WARN, ERROR
export TF_LOG=DEBUG
# Optionally write logs to a file
export TF_LOG_PATH=./terraform-debug.log

terraform plan --out plan.out
terraform apply plan.out
```

Inspect state and attributes:
```bash path=null start=null
terraform state list
terraform state show <resource_address>
# Example:
# terraform state show cudo_vm.instance
```

If a run gets stuck or a resource drifts, try:
- `terraform refresh` or `terraform apply -refresh-only` to sync state
- `terraform taint <resource_address>` to force recreation on next apply (use cautiously)

---

## Notes on security

- Do not commit API keys or sensitive data. Prefer environment variables (`TF_VAR_*`).
- If you use a local `terraform.tfvars`, add it to `.gitignore`.
- If `variables.tf` is encrypted or unavailable, create your own variable declarations as shown above.
