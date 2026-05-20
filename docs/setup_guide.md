# Wazuh Detection-as-Code: Setup Guide
<!-- Last updated: 2026-05-20 -->

## Navigation

[Architecture](architecture.md) | [Security](security.md) | [Troubleshooting](troubleshooting.md)

## Table of Contents

- [Before You Begin](#before-you-begin)
- [Prerequisites](#prerequisites)
- [Phase 1: Create the GitHub Repository](#phase-1-create-the-github-repository)
- [Phase 2: Prepare the Wazuh Server](#phase-2-prepare-the-wazuh-server)
- [Phase 3: Install the Deploy Script](#phase-3-install-the-deploy-script)
- [Phase 4: Configure Sudoers](#phase-4-configure-sudoers)
- [Phase 5: Create Required Directories](#phase-5-create-required-directories)
- [Phase 6: Install the GitHub Actions Self-Hosted Runner](#phase-6-install-the-github-actions-self-hosted-runner)
- [Phase 7: Configure Slack Notifications (Optional)](#phase-7-configure-slack-notifications-optional)
- [Phase 8: Configure Syslog Routing (Optional)](#phase-8-configure-syslog-routing-optional)
- [Phase 9: Test the Full Pipeline](#phase-9-test-the-full-pipeline)
- [Phase 10: Protect the Main Branch](#phase-10-protect-the-main-branch)
- [Operational Workflow](#operational-workflow)
- [Updating the Deploy Script](#updating-the-deploy-script)

## Before You Begin

This guide walks you through setting up a complete Detection-as-Code pipeline for your Wazuh SIEM. By the end, you will have:

- A GitHub repository storing your Wazuh rules and decoders as version-controlled code
- An automated CI/CD pipeline that validates rule changes on pull requests and deploys them on merge
- A self-hosted GitHub Actions runner on your Wazuh server that executes deployments locally
- A deploy script with automatic backup, validation, and rollback capabilities
- Branch protection ensuring all changes go through peer review and automated checks
- Optional Slack notifications and syslog routing for operational visibility

The setup is divided into 10 phases. Phases 1–6 are required for a working pipeline; Phases 7–8 are optional enhancements; Phases 9–10 validate and harden the setup.

**Estimated time:** 2–3 hours for a first-time setup. If you are already familiar with GitHub Actions runners and Wazuh server administration, expect closer to 1–1.5 hours.

For a conceptual overview of how all these components fit together before you start, see [Architecture: Pipeline Components](architecture.md#pipeline-components) and [Architecture: End-to-End Data Flow](architecture.md#end-to-end-data-flow).

## Prerequisites

Each prerequisite below includes an explanation of why it is needed, how to verify it, and what to do if it is not met.

### Wazuh Manager Server (RHEL/CentOS/Rocky Linux)

**Why:** The deploy script uses `systemctl` to manage the `wazuh-manager` service and expects file paths specific to the Wazuh RPM installation (`/var/ossec/etc/rules/`, `/var/ossec/etc/decoders/`). The pipeline is designed for RHEL-family distributions where these paths and service management conventions apply.

**On the Wazuh server, as root:**

```bash
systemctl status wazuh-manager
```

**Expected output:**

```
● wazuh-manager.service - Wazuh manager
     Loaded: loaded (/etc/systemd/system/wazuh-manager.service; enabled)
     Active: active (running)
```

**If not met:** Install the Wazuh manager following the [official Wazuh documentation](https://documentation.wazuh.com/current/installation-guide/index.html). This pipeline requires Wazuh 4.x or later on a RHEL/CentOS/Rocky Linux host.

---

### Root or Sudo Access

**Why:** Several setup steps require root privileges: creating system users, installing the deploy script with restricted permissions, configuring sudoers, and setting the immutable file attribute. Day-to-day pipeline operation does not require manual root access — only the initial setup does.

**On the Wazuh server:**

```bash
whoami
```

**Expected output:**

```
root
```

Or, if using sudo:

```bash
sudo -v
```

**Expected output:**

```
(no output, returns to prompt without error)
```

**If not met:** Contact your system administrator to obtain root or sudo access on the Wazuh server. All commands in this guide that require elevated privileges are annotated with "as root."

---

### Git (version 2.x or later)

**Why:** The deploy script uses `git fetch` and `git reset --hard` to pull the latest rule definitions from GitHub. Git must be installed on the Wazuh server for the pipeline to function. Version 2.x is required for the `fetch` options used by the script.

**On the Wazuh server, as root:**

```bash
git --version
```

**Expected output:**

```
git version 2.39.3
```

(Any version 2.x or later is acceptable.)

**If not met:** Install Git using your package manager:

```bash
dnf install -y git
```

---

### A GitHub Account (or GitHub Enterprise)

**Why:** The repository, CI/CD workflows, branch protection, and self-hosted runner registration all require a GitHub account with permission to create repositories and configure repository settings. If your organization uses GitHub Enterprise, the same steps apply with your enterprise URL.

**On your local machine:**

```bash
gh auth status
```

**Expected output:**

```
github.com
  ✓ Logged in to github.com
```

(If you do not use the `gh` CLI, verify you can log in at [github.com](https://github.com) or your enterprise instance.)

**If not met:** Create a GitHub account at [github.com/signup](https://github.com/signup), or request access to your organization's GitHub Enterprise instance from your IT team.

---

### Network Access from the Server to GitHub

**Why:** The self-hosted runner needs to establish outbound HTTPS connections to GitHub to receive workflow jobs. The deploy script's `git fetch` also requires outbound access to pull repository updates. No inbound ports need to be opened — all communication is outbound from the server.

**On the Wazuh server, as root:**

```bash
curl -sI https://github.com | head -1
```

**Expected output:**

```
HTTP/2 200
```

**If not met:** Work with your network team to allow outbound HTTPS (port 443) from the Wazuh server to:
- `github.com`
- `api.github.com`
- `*.actions.githubusercontent.com`

See [GitHub's documentation on self-hosted runner networking](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#communication-between-self-hosted-runners-and-github) for the full list of required endpoints.

---

### Slack Workspace (Optional)

**Why:** The deploy workflow can send notifications to a Slack channel on successful or failed deployments. This provides immediate visibility into pipeline activity without checking GitHub. This prerequisite is only needed if you plan to complete Phase 7.

**Verify:** Confirm you can access your Slack workspace at `https://YOUR-WORKSPACE.slack.com` and have permission to create apps or incoming webhooks (or ask a workspace admin).

**If not met:** Skip Phase 7. The pipeline functions fully without Slack notifications — you can always add them later.

## Phase 1: Create the GitHub Repository

This phase establishes the Git repository that will serve as the single source of truth for all your Wazuh detection rules and decoders. Everything in the pipeline flows from this repository — without it, there is nothing to validate, deploy, or roll back. By storing rules as code in version control, you gain audit trails, peer review, and the ability to revert any change instantly. For a deeper explanation of why this approach is superior to editing rules directly on the server, see [Architecture: Detection-as-Code Philosophy](architecture.md#detection-as-code-philosophy).

### 1.1 Create a new repository

**On your local machine:**

```bash
mkdir wazuh-dac && cd wazuh-dac
git init
```

### 1.2 Create the directory structure

**On your local machine:**

```bash
mkdir -p rules decoders scripts .github/workflows
```

### 1.3 Seed with your existing Wazuh rules and decoders

Copy your current production rules and decoders from the Wazuh server so the repository starts with your existing detection coverage.

**On your local machine (pulling from the server):**

```bash
scp -r user@WAZUH_SERVER:/var/ossec/etc/rules/*.xml rules/
scp -r user@WAZUH_SERVER:/var/ossec/etc/decoders/*.xml decoders/
```

Or, if you are working directly on the Wazuh server:

**On the Wazuh server, as root:**

```bash
cp /var/ossec/etc/rules/*.xml rules/
cp /var/ossec/etc/decoders/*.xml decoders/
```

> ⚠️ **Pitfall:** Do not copy `ossec.conf`, `internal_options.conf`, or files from `shared/` or `lists/` into the repository. These are managed separately by Wazuh and should not be deployed through the pipeline. The `.gitignore` in step 1.8 excludes them, but avoid adding them in the first place.

### 1.4 Add the deploy script

Copy `scripts/wazuh_deploy.sh` into your repository's `scripts/` directory. This is the source copy — it will be installed to the server separately in Phase 3.

**On your local machine:**

```bash
cp /path/to/wazuh_deploy.sh scripts/wazuh_deploy.sh
```

### 1.5 Add the rule ID checker

Copy `check_rule_ids.py` to the repository root. This script is used by the PR validation workflow to detect duplicate rule IDs before they reach production.

**On your local machine:**

```bash
cp /path/to/check_rule_ids.py check_rule_ids.py
```

### 1.6 Add the GitHub Actions workflows

Copy both workflow files into `.github/workflows/`:

- `integrate_rulesets.yml` — deploys rules on push to `main`
- `check_rule_ids.yml` — validates rule IDs on pull requests

For details on how these two workflows interact, see [Architecture: Workflow Relationship](architecture.md#workflow-relationship).

**On your local machine:**

```bash
cp /path/to/integrate_rulesets.yml .github/workflows/
cp /path/to/check_rule_ids.yml .github/workflows/
```

### 1.7 Add .gitignore

Create a `.gitignore` to prevent sensitive or irrelevant Wazuh files from being committed:

**On your local machine:**

```bash
cat > .gitignore << 'EOF'
client.keys
internal_options.conf
local_internal_options.conf
ossec.conf
sslmanager.cert
localtime
sslmanager.key
lists/
rootcheck/
shared/
EOF
```

### 1.8 Push to GitHub

**On your local machine:**

```bash
git add .
git commit -m "Initial commit: Wazuh DaC pipeline"
git remote add origin git@github.com:YOUR_ORG/wazuh-dac.git
git push -u origin main
```

> ⚠️ **Pitfall:** If your repository is private, you will need to configure authentication for the Wazuh server to fetch from it. This is covered in Phase 2 (deploy keys). Make sure you do not skip that step, or the deploy script will fail on `git fetch`.

---

## Phase 2: Prepare the Wazuh Server

This phase creates the dedicated service account that the GitHub Actions runner will use and clones the repository to the server. The `ci-runner` user is deliberately unprivileged — it exists solely to run the Actions runner process and invoke the deploy script via sudo. This separation ensures that even if the runner is compromised, the attacker cannot directly access production rules, backups, or system services. For the full security rationale, see [Security: Principle of Least Privilege](security.md#principle-of-least-privilege).

All commands in this phase are run on the Wazuh server as root.

### 2.1 Create the ci-runner user

**On the Wazuh server, as root:**

```bash
useradd -r -m -s /bin/bash ci-runner
```

**Expected output:**

```
(no output — the command succeeds silently)
```

Verify the user was created:

**On the Wazuh server, as root:**

```bash
id ci-runner
```

**Expected output:**

```
uid=XXX(ci-runner) gid=XXX(ci-runner) groups=XXX(ci-runner)
```

> ⚠️ **Pitfall:** Do not add `ci-runner` to the `wazuh` group or any other privileged group. The user should have no access to production rule files or Wazuh configuration. All deployment operations happen through the deploy script running as root via sudo.

### 2.2 Clone the repository

**On the Wazuh server, as root:**

```bash
git clone https://github.com/YOUR_ORG/wazuh-dac.git /opt/wazuh-dac
chown -R root:root /opt/wazuh-dac
```

If the repository is private, configure a deploy key (a read-only SSH key tied to a single repository — it cannot push changes or access other repos) or a Personal Access Token (PAT) for git access:

**Option A: Deploy key (read-only, recommended)**

Deploy keys are SSH keys that grant read-only access to a single repository. They are preferred over PATs because they cannot be used to access other repositories or perform write operations.

**On the Wazuh server, as root:**

```bash
ssh-keygen -t ed25519 -f /root/.ssh/wazuh-dac-deploy -N ""
cat /root/.ssh/wazuh-dac-deploy.pub
```

**Expected output:**

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... root@wazuh-server
```

Add the public key to your GitHub repository: Settings → Deploy Keys → Add deploy key (check "Allow read access" only).

Then configure git to use the deploy key:

**On the Wazuh server, as root:**

```bash
git config --global core.sshCommand "ssh -i /root/.ssh/wazuh-dac-deploy"
```

**Option B: HTTPS with PAT stored in credential helper**

**On the Wazuh server, as root:**

```bash
git config --global credential.helper store
```

The PAT will be prompted on first fetch. Store it securely — it grants access to the repository.

> ⚠️ **Pitfall:** If using a PAT, ensure it has only `repo` (read) scope. A PAT with write access could be exploited if the server is compromised. Deploy keys are preferred because they are inherently read-only and scoped to a single repository.

### 2.3 Verify the clone

**On the Wazuh server, as root:**

```bash
ls /opt/wazuh-dac/rules/*.xml
ls /opt/wazuh-dac/decoders/*.xml
```

**Expected output:**

```
/opt/wazuh-dac/rules/local_rules.xml
/opt/wazuh-dac/rules/1000-windows-rules-tuned.xml
...
/opt/wazuh-dac/decoders/local_decoder.xml
```

(You should see your rule and decoder XML files listed.)

---

## Phase 3: Install the Deploy Script

This phase installs the deploy script to its production location and protects it with the immutable file attribute. The script is the core of the deployment pipeline — it handles git fetch, backup, file sync, validation, service restart, and auto-rollback. Installing it at a fixed path (`/usr/local/bin/wazuh-deploy.sh`) with root ownership and the immutable attribute ensures that it cannot be tampered with, even by root, without explicitly removing the protection first. For a detailed explanation of why immutability matters, see [Security: Immutable Script Attribute (chattr +i)](security.md#immutable-script-attribute-chattr-i).

### 3.1 Copy the script to its production location

**On the Wazuh server, as root:**

```bash
cp /opt/wazuh-dac/scripts/wazuh_deploy.sh /usr/local/bin/wazuh-deploy.sh
```

### 3.2 Set ownership and permissions

**On the Wazuh server, as root:**

```bash
chown root:root /usr/local/bin/wazuh-deploy.sh
chmod 0755 /usr/local/bin/wazuh-deploy.sh
```

### 3.3 Set the immutable attribute

The `chattr +i` command sets the Linux immutable file attribute, which prevents any modification, deletion, or renaming of the file — even by root — until the attribute is explicitly removed with `chattr -i`. This protects the deploy script from tampering.

**On the Wazuh server, as root:**

```bash
chattr +i /usr/local/bin/wazuh-deploy.sh
```

### 3.4 Verify the installation

**On the Wazuh server, as root:**

```bash
lsattr /usr/local/bin/wazuh-deploy.sh
```

**Expected output:**

```
----i---------e-- /usr/local/bin/wazuh-deploy.sh
```

The `i` in the fifth position confirms the immutable attribute is set.

**On the Wazuh server, as root:**

```bash
ls -la /usr/local/bin/wazuh-deploy.sh
```

**Expected output:**

```
-rwxr-xr-x 1 root root ... /usr/local/bin/wazuh-deploy.sh
```

> ⚠️ **Pitfall:** If you forget to set the immutable attribute (`chattr +i`), the GitHub Actions workflow's pre-flight check will fail on the next deployment with the error "Deploy script immutable attribute not set. Aborting." Always verify with `lsattr` after installation. If you need to update the script later, see [Updating the Deploy Script](#updating-the-deploy-script) for the safe procedure.

---

## Phase 4: Configure Sudoers

This phase grants the `ci-runner` user permission to execute the deploy script as root — and nothing else. The sudoers rule uses `NOPASSWD` (so the GitHub Actions runner can invoke it without interactive authentication) and `NOSETENV` (which prevents the caller from injecting environment variables into the root execution context). This is a critical security boundary: without `NOSETENV`, an attacker who compromises the runner could pass `LD_PRELOAD` or `PATH` overrides through sudo, bypassing the script's own environment sanitization. For the full security analysis, see [Security: Sudoers Configuration (NOPASSWD:NOSETENV)](security.md#sudoers-configuration-nopasswdnosetenv).

### 4.1 Create the sudoers drop-in file

**On the Wazuh server, as root:**

```bash
cat > /etc/sudoers.d/github-actions << 'EOF'
ci-runner ALL=(root) NOPASSWD:NOSETENV: /usr/local/bin/wazuh-deploy.sh
EOF
```

The `NOSETENV` flag instructs sudo to strip all user-supplied environment variables before executing the target command. This means even if an attacker sets `LD_PRELOAD=/tmp/evil.so` before calling sudo, the variable is discarded before the script starts.

### 4.2 Set permissions on the sudoers file

**On the Wazuh server, as root:**

```bash
chown root:root /etc/sudoers.d/github-actions
chmod 0440 /etc/sudoers.d/github-actions
```

> ⚠️ **Pitfall:** Sudoers files must be owned by root and have mode `0440`. If the permissions are wrong, sudo will refuse to read the file and the deploy workflow will fail with a "permission denied" error. Never use `chmod 644` or any other mode.

### 4.3 Validate the sudoers syntax

**On the Wazuh server, as root:**

```bash
visudo -c -f /etc/sudoers.d/github-actions
```

**Expected output:**

```
/etc/sudoers.d/github-actions: parsed OK
```

Also validate the full sudoers configuration to ensure no conflicts:

**On the Wazuh server, as root:**

```bash
visudo -c
```

**Expected output:**

```
/etc/sudoers: parsed OK
/etc/sudoers.d/github-actions: parsed OK
```

> ⚠️ **Pitfall:** Never edit sudoers files with a regular text editor (`vim`, `nano`). If you introduce a syntax error, sudo may stop working entirely, locking you out of root access. Always use `visudo` for editing, or write the file and immediately validate with `visudo -c`. If you do get locked out, you will need console access to the server to fix it.

### 4.4 Test the sudo rule

Verify that `ci-runner` can invoke the script (it will fail because preconditions are not yet met, but sudo itself should work):

**On the Wazuh server, as root:**

```bash
su -s /bin/bash -c "sudo /usr/local/bin/wazuh-deploy.sh" ci-runner
echo "Exit code: $?"
```

**Expected output:**

```
Exit code: 1
```

An exit code of 1 is expected at this stage — it means sudo worked correctly but the deploy script's precondition checks failed (the backup directory does not exist yet). If you see "permission denied" or "ci-runner is not in the sudoers file," revisit steps 4.1–4.2.

---

## Phase 5: Create Required Directories

This phase creates the directories that the deploy script expects to exist before it can run successfully. The backup directory (`/var/ossec/actions-backups`) stores compressed tar archives of the production configuration before each deployment, enabling automatic rollback if anything goes wrong. The target directories (`/var/ossec/etc/rules/` and `/var/ossec/etc/decoders/`) should already exist on a running Wazuh server, but this step verifies they are present and correctly owned. For details on how backups are created and retained, see [Architecture: Backup and Rollback Lifecycle](architecture.md#backup-and-rollback-lifecycle).

### 5.1 Create the backup directory

**On the Wazuh server, as root:**

```bash
mkdir -p /var/ossec/actions-backups
chown root:root /var/ossec/actions-backups
chmod 0750 /var/ossec/actions-backups
```

The backup directory is owned by root with mode `0750` because backup archives contain the full production configuration (rules and decoders). Only root should be able to read or write backups — the `ci-runner` user and other non-root accounts should not have access to previous configurations.

**Expected output:**

```
(no output — the commands succeed silently)
```

Verify:

**On the Wazuh server, as root:**

```bash
ls -ld /var/ossec/actions-backups
```

**Expected output:**

```
drwxr-x--- 2 root root ... /var/ossec/actions-backups
```

> ⚠️ **Pitfall:** The backup directory path is `/var/ossec/actions-backups` (not `/var/ossec/backups`). The deploy script uses this exact path — if you create the directory at a different location, the script will fail when attempting to write backup archives. Check the `BACKUP_BASE` variable in the script if unsure.

### 5.2 Verify target directories exist

The production rule and decoder directories should already exist on a running Wazuh server. Verify they are present and owned by the `wazuh` user:

**On the Wazuh server, as root:**

```bash
ls -ld /var/ossec/etc/rules/
ls -ld /var/ossec/etc/decoders/
```

**Expected output:**

```
drwxr-x--- ... wazuh wazuh ... /var/ossec/etc/rules/
drwxr-x--- ... wazuh wazuh ... /var/ossec/etc/decoders/
```

If these directories do not exist or have incorrect ownership, your Wazuh installation may be incomplete. Verify the Wazuh manager is installed and running:

**On the Wazuh server, as root:**

```bash
systemctl status wazuh-manager
```

**Expected output:**

```
● wazuh-manager.service - Wazuh manager
     Loaded: loaded (/etc/systemd/system/wazuh-manager.service; enabled)
     Active: active (running)
```

> ⚠️ **Pitfall:** Do not manually create `/var/ossec/etc/rules/` or `/var/ossec/etc/decoders/` if they are missing. Their absence indicates the Wazuh manager is not properly installed. Install or reinstall the Wazuh manager first — the directories are created automatically during installation with the correct ownership and SELinux context.

## Phase 6: Install the GitHub Actions Self-Hosted Runner

A self-hosted runner is a machine you manage that executes GitHub Actions workflow jobs locally rather than on GitHub's cloud infrastructure. This pipeline requires a self-hosted runner because the deploy workflow must run directly on the Wazuh server to access local files, restart the `wazuh-manager` service, and perform health checks. For a deeper explanation of why self-hosted runners are used and their security implications, see [Architecture: GitHub Actions Self-Hosted Runner](architecture.md#github-actions-self-hosted-runner).

### 6.1 Download the runner

**On the Wazuh server, as ci-runner:**

```bash
su - ci-runner
mkdir -p ~/actions-runner && cd ~/actions-runner
```

Navigate to your GitHub repository → Settings → Actions → Runners → **New self-hosted runner**. Select **Linux** and **x64**, then follow the download instructions. The commands will look similar to:

```bash
curl -o actions-runner-linux-x64-2.321.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-x64-2.321.0.tar.gz
tar xzf actions-runner-linux-x64-2.321.0.tar.gz
```

> ⚠️ **Pitfall:** Always use the download URL shown in your GitHub repository settings — the version number changes frequently. Do not copy the URL above verbatim; it may be outdated by the time you read this.

### 6.2 Configure the runner

**On the Wazuh server, as ci-runner:**

```bash
./config.sh --url https://github.com/YOUR_ORG/wazuh-dac --token YOUR_TOKEN
```

When prompted, use these settings:
- **Runner group:** `Default`
- **Runner name:** `wazuh-server` (or a name that identifies this host)
- **Labels:** `self-hosted,linux` (the defaults are fine — the workflow uses `runs-on: self-hosted`)
- **Work folder:** `_work` (default)

The registration token (`YOUR_TOKEN`) is displayed on the GitHub runner setup page and expires after one hour. If it expires, generate a new one from the same page.

> ⚠️ **Pitfall:** The runner must be configured as the `ci-runner` user, not as root. If you configure it as root, the runner process will run with elevated privileges, violating the principle of least privilege. See [Security: Principle of Least Privilege](security.md#principle-of-least-privilege) for why this matters.

### 6.3 Install as a service

**On the Wazuh server, as root:**

```bash
cd /home/ci-runner/actions-runner
./svc.sh install ci-runner
./svc.sh start
./svc.sh status
```

**Expected output:**

```
● actions.runner.YOUR_ORG-wazuh-dac.wazuh-server.service
     Loaded: loaded (/etc/systemd/system/actions.runner.YOUR_ORG-wazuh-dac.wazuh-server.service; enabled)
     Active: active (running)
```

The `install ci-runner` argument tells the service manager to run the runner process as the `ci-runner` user. This ensures the runner operates with limited privileges and can only escalate to root through the tightly scoped sudoers rule configured in Phase 4.

### 6.4 Verify the runner appears in GitHub

**In your browser:**

Navigate to your repository → Settings → Actions → Runners. You should see your runner listed with status **Idle** (a green dot).

If the runner shows as **Offline**, check:
1. The service is running: `systemctl status actions.runner.*`
2. The server can reach GitHub: `curl -sI https://github.com | head -1`
3. Firewall allows outbound HTTPS (port 443)

For detailed runner connectivity troubleshooting, see [Troubleshooting: Runner Connectivity Issues](troubleshooting.md#runner-connectivity-issues).

---

## Phase 7: Configure Slack Notifications (Optional)

This phase configures Slack notifications so your team receives immediate alerts when deployments succeed or fail. This is optional — the pipeline functions fully without it — but it provides valuable operational visibility without requiring anyone to watch the GitHub Actions tab.

### 7.1 Create a Slack Incoming Webhook

**In your browser:**

1. Go to [https://api.slack.com/apps](https://api.slack.com/apps)
2. Click **Create New App** → **From scratch**
3. Name the app (e.g., "Wazuh Deploy Notifications") and select your workspace
4. In the left sidebar, click **Incoming Webhooks** → toggle **Activate Incoming Webhooks** to On
5. Click **Add New Webhook to Workspace** → select the channel for notifications
6. Copy the webhook URL (it looks like `https://hooks.slack.com/services/T.../B.../xxx`)

> ⚠️ **Pitfall:** The webhook URL is a secret — anyone with it can post to your Slack channel. Never commit it to the repository. It will be stored as a GitHub encrypted secret in the next step.

### 7.2 Add the secret to GitHub

**In your browser:**

Navigate to your repository → Settings → Secrets and variables → Actions → **New repository secret**:
- **Name:** `SLACK_WEBHOOK_URL`
- **Value:** paste the webhook URL from step 7.1

The deploy workflow (`.github/workflows/integrate_rulesets.yml`) already references this secret. When the secret exists, notifications are sent automatically on both success and failure. If the secret is not configured, the notification steps silently skip (the `curl` command fails gracefully).

---

## Phase 8: Configure Syslog Routing (Optional)

This phase routes the deploy script's structured log messages to a dedicated log file for easier monitoring and log rotation. By default, the deploy script logs to syslog using the tag `actions-wazuh-deploy` and facility `local6` (a user-definable syslog facility reserved for local use). Without this routing, deploy logs are mixed into `/var/log/messages` with all other system messages.

**On the Wazuh server, as root:**

```bash
cat > /etc/rsyslog.d/wazuh-deploy.conf << 'EOF'
# Route all deploy script logs (facility local6) to a dedicated file
local6.*    /var/log/wazuh-deploy.log
EOF
```

Restart rsyslog to apply the new routing rule:

```bash
systemctl restart rsyslog
```

**Expected output:**

```
(no output — silent success)
```

Verify the configuration was loaded:

```bash
systemctl status rsyslog | grep active
```

**Expected output:**

```
     Active: active (running)
```

After the next deployment, you can view deploy-specific logs with:

```bash
tail -f /var/log/wazuh-deploy.log
```

> ⚠️ **Pitfall:** If you see no output in `/var/log/wazuh-deploy.log` after a deployment, verify that the deploy script's `LOG_FACILITY` variable is set to `local6`. The routing rule only captures messages sent to the `local6` facility. Also ensure SELinux is not blocking rsyslog from writing to the new file — check with `ausearch -m avc -ts recent`.

---

## Phase 9: Test the Full Pipeline

This phase validates that all components work together end-to-end: the deploy script executes correctly, the GitHub Actions workflow triggers and completes, and notifications arrive. Testing now — before relying on the pipeline in production — catches configuration issues while they are easy to diagnose.

### 9.1 Test the deploy script manually

**On the Wazuh server, as root:**

```bash
sudo /usr/local/bin/wazuh-deploy.sh
echo "Exit code: $?"
```

**Expected output:**

```
Exit code: 0
```

An exit code of `0` means the deploy completed successfully. The script produces no stdout on success — all output goes to syslog. Verify the syslog entry:

**On the Wazuh server, as root:**

```bash
grep actions-wazuh-deploy /var/log/messages | tail -5
```

**Expected output:**

```
<timestamp> <hostname> actions-wazuh-deploy: event=deploy_complete outcome=success duration_s=<N>
```

If the script exits with code `1`, a precondition check failed (e.g., missing directories, environment contamination). If it exits with code `2`, an operational step failed (e.g., git fetch, config validation). Check the syslog for `reason=` or `phase=` fields that identify the failure. See [Troubleshooting: Deploy Script Precondition Failures](troubleshooting.md#deploy-script-precondition-failures) for detailed diagnostics.

> ⚠️ **Pitfall:** If you run the deploy script and see `event=precondition_failed reason=env_contamination`, you likely ran it with `sudo -E` (which preserves environment variables) or from a shell with custom environment. The script intentionally rejects any inherited environment. Always invoke it with plain `sudo /usr/local/bin/wazuh-deploy.sh` — no flags, no arguments.

### 9.2 Test the GitHub Actions workflow

**In your browser:**

1. Navigate to your repository → Actions → **"Update Rulesets on SIEM"**
2. Click **Run workflow** → select the `main` branch → click **Run workflow**
3. Watch the workflow run complete (typically 30–60 seconds)

The workflow should show a green checkmark. If it fails, click into the run to see which step failed and check the runner's syslog for details.

### 9.3 Test the full flow end-to-end

**On your local machine:**

```bash
git checkout -b test/pipeline-validation
echo "<!-- pipeline test -->" >> rules/local_rules.xml
git add rules/local_rules.xml
git commit -m "test: validate deploy pipeline end-to-end"
git push -u origin test/pipeline-validation
```

Open a pull request from `test/pipeline-validation` → `main`. The `check-rule-ids` workflow should run and pass. Merge the PR, then:

1. Watch the **Actions** tab — the "Update Rulesets on SIEM" workflow should trigger automatically
2. Check Slack (if configured) — you should receive a success notification
3. Verify on the server:

**On the Wazuh server, as root:**

```bash
grep "pipeline test" /var/ossec/etc/rules/local_rules.xml
```

**Expected output:**

```
<!-- pipeline test -->
```

After confirming the pipeline works, clean up the test comment from your rules file.

> ⚠️ **Pitfall:** If the workflow does not trigger after merging, verify that the push was to the `main` branch and that the changed file matches the path filter (`**.xml`) in the workflow's `on.push.paths` configuration. Non-XML file changes do not trigger the deploy workflow.

---

## Phase 10: Protect the Main Branch

This phase enables branch protection rules that enforce peer review and automated validation before any changes reach the `main` branch. Once enabled, direct pushes to `main` are blocked — all changes must go through a pull request. This is the final safeguard ensuring that invalid or unreviewed rules never reach production automatically.

### 10.1 Configure branch protection

**In your browser:**

Navigate to your repository → Settings → Branches → **Add branch protection rule**:

- **Branch name pattern:** `main`
- Enable the following:
  - ✅ **Require a pull request before merging** — ensures at least one reviewer approves changes
  - ✅ **Require status checks to pass before merging** — select `check-rule-ids` from the list
  - ✅ **Do not allow bypassing the above settings** — applies rules to administrators too

Click **Create** to save the rule.

### 10.2 Verify branch protection is active

**On your local machine:**

```bash
git checkout main
echo "<!-- should fail -->" >> rules/local_rules.xml
git add rules/local_rules.xml
git commit -m "test: verify branch protection blocks direct push"
git push origin main
```

**Expected output:**

```
remote: error: GH006: Protected branch update failed for refs/heads/main.
remote: error: Required status check "check-rule-ids" is expected.
! [remote rejected] main -> main (protected branch hook declined)
```

This confirms that direct pushes are blocked. Reset your local branch:

```bash
git reset --hard HEAD~1
```

> ⚠️ **Pitfall:** If you select "Require status checks to pass" but the `check-rule-ids` check does not appear in the list, it means the check has never run on the repository. Run it at least once (by opening any PR that modifies an XML file) before configuring branch protection. GitHub only shows status checks that have previously reported results.

---

## Operational Workflow

With the pipeline fully deployed, the day-to-day workflow for managing Wazuh rules follows a standard Git branching model. No manual server access is needed for routine rule changes — the pipeline handles deployment automatically.

### The Standard Workflow

```
┌─────────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────────┐     ┌─────────┐
│ Create      │────►│ Edit XML │────►│ Push &   │────►│ Merge to │────►│ Auto-deploy  │────►│ Monitor │
│ Branch      │     │ Files    │     │ Open PR  │     │ main     │     │ (Actions)    │     │         │
└─────────────┘     └──────────┘     └──────────┘     └──────────┘     └──────────────┘     └─────────┘
```

### Step-by-Step

1. **Create a branch** for your rule changes:

   **On your local machine:**

   ```bash
   git checkout main && git pull
   git checkout -b feature/add-brute-force-rule
   ```

2. **Edit XML files** in `rules/` or `decoders/`:

   **On your local machine:**

   ```bash
   # Edit rules using your preferred editor
   vim rules/local_rules.xml
   ```

   Follow the existing rule ID conventions. The `check_rule_ids.py` script validates that rule IDs do not conflict across files.

3. **Push and open a PR** — the rule ID checker validates automatically:

   **On your local machine:**

   ```bash
   git add rules/local_rules.xml
   git commit -m "feat: add brute-force detection rule (ID 100200)"
   git push -u origin feature/add-brute-force-rule
   ```

   Open a pull request in GitHub. The `check-rule-ids` workflow runs automatically and validates XML syntax and rule ID uniqueness. See [Architecture: Workflow Relationship](architecture.md#workflow-relationship) for details on what this check validates.

4. **Merge to main** — the deploy workflow runs automatically:

   After the PR is approved and status checks pass, merge it. The `integrate_rulesets.yml` workflow triggers on any push to `main` that modifies `**.xml` files. The self-hosted runner executes `sudo /usr/local/bin/wazuh-deploy.sh`, which fetches the latest code, backs up the current config, syncs files, validates, restarts Wazuh, and runs a health check.

5. **Monitor** — Slack notification confirms success or failure:

   If Slack is configured (Phase 7), you receive a notification within seconds of deployment completing. The notification includes the commit SHA, actor, and a link to the workflow run.

   For syslog monitoring (Phase 8):

   **On the Wazuh server, as root:**

   ```bash
   tail -1 /var/log/wazuh-deploy.log
   ```

   **Expected output:**

   ```
   <timestamp> <hostname> actions-wazuh-deploy: event=deploy_complete outcome=success duration_s=<N>
   ```

6. **If failure** — the script auto-rolls back and logs the reason:

   The deploy script automatically restores the previous configuration if validation or restart fails. Check the logs for the failure reason:

   **On the Wazuh server, as root:**

   ```bash
   grep actions-wazuh-deploy /var/log/messages | grep -E "rollback|failed" | tail -5
   ```

   For detailed failure diagnosis, see [Troubleshooting: Issues by Symptom](troubleshooting.md#how-to-use-this-guide).

---

## Updating the Deploy Script

The deploy script at `/usr/local/bin/wazuh-deploy.sh` is protected with the Linux immutable file attribute (`chattr +i`). This attribute prevents any modification or deletion — even by root — until it is explicitly removed. This protection exists to prevent accidental or malicious tampering with the script between deployments. For the full security rationale, see [Security: Immutable Script Attribute (chattr +i)](security.md#immutable-script-attribute-chattr-i).

When you modify `scripts/wazuh_deploy.sh` in the repository, the change is **not** automatically deployed to the server. The deploy script is intentionally excluded from the automated sync (only `rules/` and `decoders/` are synced). You must manually update the installed copy using the procedure below.

### Safe Update Procedure

**On the Wazuh server, as root:**

```bash
# 1. Remove the immutable attribute to allow modification
chattr -i /usr/local/bin/wazuh-deploy.sh

# 2. Pull the latest version from the repository
cd /opt/wazuh-dac && git pull

# 3. Copy the updated script into place
cp /opt/wazuh-dac/scripts/wazuh_deploy.sh /usr/local/bin/wazuh-deploy.sh

# 4. Restore ownership and permissions
chown root:root /usr/local/bin/wazuh-deploy.sh
chmod 0700 /usr/local/bin/wazuh-deploy.sh

# 5. Re-apply the immutable attribute
chattr +i /usr/local/bin/wazuh-deploy.sh
```

Verify the update was applied correctly:

**On the Wazuh server, as root:**

```bash
lsattr /usr/local/bin/wazuh-deploy.sh
```

**Expected output:**

```
----i---------e-- /usr/local/bin/wazuh-deploy.sh
```

```bash
ls -la /usr/local/bin/wazuh-deploy.sh
```

**Expected output:**

```
-rwx------ 1 root root <size> <date> /usr/local/bin/wazuh-deploy.sh
```

> ⚠️ **Pitfall:** If you forget to re-apply `chattr +i` after updating, the next deployment will still succeed — but the script loses its tamper protection. Always verify with `lsattr` as the final step. If the workflow includes an immutability pre-flight check (currently commented out in the workflow file), a missing immutable attribute will cause deployments to fail until it is restored.

### Using the Install Script (Alternative)

If an install script is available in the repository, you can use it as a shortcut:

**On the Wazuh server, as root:**

```bash
chattr -i /usr/local/bin/wazuh-deploy.sh 2>/dev/null || true
/opt/wazuh-dac/scripts/install-deploy-script.sh /opt/wazuh-dac/scripts/wazuh_deploy.sh
```

The install script handles copying, setting permissions, and applying the immutable attribute in one step. The `2>/dev/null || true` on the first command handles the case where the attribute is already removed or the file does not yet exist.
