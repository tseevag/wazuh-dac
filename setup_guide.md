# Full Setup Guide: Wazuh Detection-as-Code Pipeline

Deploy this automated SIEM rule management pipeline on an existing Wazuh server from scratch.

## Prerequisites

- A running Wazuh manager server (RHEL/CentOS/Rocky Linux)
- Root or sudo access on the server
- A GitHub account (or GitHub Enterprise)
- Network access from the server to GitHub (for git fetch and Actions runner)
- Slack workspace (optional, for notifications)

---

## Phase 1: Create the GitHub Repository

### 1.1 Create a new repository

```bash
# On your local machine
mkdir wazuh-dac && cd wazuh-dac
git init
```

### 1.2 Create the directory structure

```bash
mkdir -p rules decoders scripts .github/workflows
```

### 1.3 Seed with your existing Wazuh rules and decoders

Copy your current production rules and decoders from the Wazuh server:

```bash
# From the Wazuh server
scp -r user@WAZUH_SERVER:/var/ossec/etc/rules/*.xml rules/
scp -r user@WAZUH_SERVER:/var/ossec/etc/decoders/*.xml decoders/
```

Or if you're on the server:

```bash
cp /var/ossec/etc/rules/*.xml rules/
cp /var/ossec/etc/decoders/*.xml decoders/
```

### 1.4 Add the deploy script

Copy `scripts/wazuh-deploy.sh` into your repo (the version from this project).

### 1.5 Add the install script

Copy `scripts/install-deploy-script.sh` into your repo.

### 1.6 Add the rule ID checker

Copy `check_rule_ids.py` to the repo root.

### 1.7 Add the GitHub Actions workflows

Copy both workflow files:
- `.github/workflows/integrate_rulesets.yml` — deploys on push to main
- `.github/workflows/check_rule_ids.yml` — validates rule IDs on PRs

### 1.8 Add .gitignore

```
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
```

### 1.9 Push to GitHub

```bash
git add .
git commit -m "Initial commit: Wazuh DaC pipeline"
git remote add origin git@github.com:YOUR_ORG/wazuh-dac.git
git push -u origin main
```

---

## Phase 2: Prepare the Wazuh Server

All commands in this phase are run on the Wazuh server as root.

### 2.1 Create the ci-runner user

```bash
useradd -r -m -s /bin/bash ci-runner
```

### 2.2 Clone the repository

```bash
git clone https://github.com/YOUR_ORG/wazuh-dac.git /opt/wazuh-dac
chown -R root:root /opt/wazuh-dac
```

If the repo is private, configure a deploy key or PAT for git access:

```bash
# Option A: Deploy key (read-only, recommended)
ssh-keygen -t ed25519 -f /root/.ssh/wazuh-dac-deploy -N ""
# Add the public key to GitHub repo → Settings → Deploy Keys (read-only)

# Configure git to use it
git config --global core.sshCommand "ssh -i /root/.ssh/wazuh-dac-deploy"
```

```bash
# Option B: HTTPS with PAT stored in credential helper
git config --global credential.helper store
# The PAT will be prompted on first fetch
```

### 2.3 Verify the clone

```bash
ls /opt/wazuh-dac/rules/*.xml
ls /opt/wazuh-dac/decoders/*.xml
```

---

## Phase 3: Install the Deploy Script

### 3.1 Install using the install script

```bash
/opt/wazuh-dac/scripts/install-deploy-script.sh /opt/wazuh-dac/scripts/wazuh-deploy.sh
```

This will:
1. Copy the script to `/usr/local/bin/wazuh-deploy.sh`
2. Set ownership to `root:root`, permissions to `0700`
3. Set the immutable attribute (`chattr +i`)
4. Verify the immutable flag

### 3.2 Verify manually

```bash
lsattr /usr/local/bin/wazuh-deploy.sh
# Expected: ----i---------e-- /usr/local/bin/wazuh-deploy.sh

ls -la /usr/local/bin/wazuh-deploy.sh
# Expected: -rwx------ 1 root root ... /usr/local/bin/wazuh-deploy.sh
```

---

## Phase 4: Configure Sudoers

### 4.1 Create the sudoers drop-in

```bash
cat > /etc/sudoers.d/github-actions << 'EOF'
ci-runner ALL=(root) NOPASSWD:NOSETENV: /usr/local/bin/wazuh-deploy.sh
EOF
```

### 4.2 Set permissions

```bash
chown root:root /etc/sudoers.d/github-actions
chmod 0440 /etc/sudoers.d/github-actions
```

### 4.3 Validate syntax

```bash
visudo -c -f /etc/sudoers.d/github-actions
# Expected: /etc/sudoers.d/github-actions: parsed OK

visudo -c
# Expected: parsed OK (full config)
```

---

## Phase 5: Create Required Directories

### 5.1 Backup directory

```bash
mkdir -p /var/ossec/backups
chown root:root /var/ossec/backups
chmod 0750 /var/ossec/backups
```

### 5.2 Ensure target directories exist

```bash
ls -la /var/ossec/etc/rules/
ls -la /var/ossec/etc/decoders/
# These should already exist on a running Wazuh server
```

---

## Phase 6: Install the GitHub Actions Self-Hosted Runner

### 6.1 Download the runner

On the Wazuh server, as the `ci-runner` user:

```bash
su - ci-runner
mkdir -p ~/actions-runner && cd ~/actions-runner
```

Go to your GitHub repo → Settings → Actions → Runners → New self-hosted runner.
Follow the download instructions for Linux x64:

```bash
curl -o actions-runner-linux-x64-2.321.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-x64-2.321.0.tar.gz
tar xzf actions-runner-linux-x64-2.321.0.tar.gz
```

### 6.2 Configure the runner

```bash
./config.sh --url https://github.com/YOUR_ORG/wazuh-dac --token YOUR_TOKEN
```

When prompted:
- Runner group: `Default`
- Runner name: `wazuh-server` (or your preference)
- Labels: `self-hosted,linux` (defaults are fine)
- Work folder: `_work` (default)

### 6.3 Install as a service

Back as root:

```bash
cd /home/ci-runner/actions-runner
./svc.sh install ci-runner
./svc.sh start
./svc.sh status
```

### 6.4 Verify the runner appears in GitHub

Go to repo → Settings → Actions → Runners. You should see your runner listed as "Idle".

---

## Phase 7: Configure Slack Notifications (Optional)

### 7.1 Create a Slack Incoming Webhook

1. Go to https://api.slack.com/apps
2. Create New App → From scratch
3. Enable "Incoming Webhooks"
4. Add a webhook to your desired channel
5. Copy the webhook URL

### 7.2 Add the secret to GitHub

Go to repo → Settings → Secrets and variables → Actions → New repository secret:
- Name: `SLACK_WEBHOOK_URL`
- Value: the webhook URL from step 7.1

---

## Phase 8: Configure Syslog Routing (Optional)

Route deploy logs to a dedicated file for easier monitoring:

```bash
cat > /etc/rsyslog.d/wazuh-deploy.conf << 'EOF'
local6.*    /var/log/wazuh-deploy.log
EOF

systemctl restart rsyslog
```

---

## Phase 9: Test the Full Pipeline

### 9.1 Test the deploy script manually

```bash
sudo /usr/local/bin/wazuh-deploy.sh
echo "Exit code: $?"
```

Expected: exit code 0 and syslog entry `event=deploy_complete outcome=success`.

```bash
grep wazuh-deploy /var/log/messages | tail -10
```

### 9.2 Test the GitHub Actions workflow

Trigger manually from GitHub:
1. Go to repo → Actions → "Update Rulesets on SIEM"
2. Click "Run workflow" → "Run workflow"
3. Watch the run complete

### 9.3 Test the full flow end-to-end

On your local machine:

```bash
# Make a trivial change to a rule file
echo "<!-- test comment -->" >> rules/local_rules.xml
git add rules/local_rules.xml
git commit -m "Test: trigger deploy pipeline"
git push origin main
```

Watch the Actions tab — the workflow should trigger, deploy, and send a Slack notification.

---

## Phase 10: Protect the Main Branch

### 10.1 Configure branch protection

Go to repo → Settings → Branches → Add rule:
- Branch name pattern: `main`
- Enable:
  - Require a pull request before merging
  - Require status checks to pass (select "check-rule-ids")
  - Do not allow bypassing the above settings

This ensures all rule changes go through PR review and pass the rule ID conflict check before deploying.

---

## Operational Workflow

Once deployed, the day-to-day workflow is:

1. **Create a branch** for your rule changes
2. **Edit XML files** in `rules/` or `decoders/`
3. **Push and open a PR** — the rule ID checker validates automatically
4. **Merge to main** — the deploy workflow runs automatically
5. **Monitor** — Slack notification confirms success or failure
6. **If failure** — check syslog, the script auto-rolls back to the previous config

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Workflow fails at immutability check | `lsattr /usr/local/bin/wazuh-deploy.sh` — re-apply `chattr +i` if missing |
| Deploy script exits with code 1 | Pre-condition failed — check syslog for `reason=` |
| Deploy script exits with code 2 | Operation failed — check syslog for `phase=` and `stderr=` |
| Runner offline in GitHub | `systemctl status actions.runner.*` on the server |
| Git fetch fails | Verify network access and credentials for root to reach GitHub |
| Concurrent execution blocked | `fuser /var/run/wazuh-deploy.lock` — kill stale process or wait |
| Rollback occurred | Check `grep rollback /var/log/messages` for the reason |

---

## Updating the Deploy Script

When you modify `scripts/wazuh-deploy.sh` in the repo, you must manually update the installed copy on the server:

```bash
# On the Wazuh server as root
chattr -i /usr/local/bin/wazuh-deploy.sh
cp /opt/wazuh-dac/scripts/wazuh-deploy.sh /usr/local/bin/wazuh-deploy.sh
chown root:root /usr/local/bin/wazuh-deploy.sh
chmod 0700 /usr/local/bin/wazuh-deploy.sh
chattr +i /usr/local/bin/wazuh-deploy.sh
lsattr /usr/local/bin/wazuh-deploy.sh   # verify 'i' flag
```

Or use the install script:

```bash
chattr -i /usr/local/bin/wazuh-deploy.sh 2>/dev/null || true
/opt/wazuh-dac/scripts/install-deploy-script.sh /opt/wazuh-dac/scripts/wazuh-deploy.sh
```

---

## Security Summary

| Layer | Control |
|-------|---------|
| GitHub | Branch protection, PR reviews, rule ID validation |
| Runner | Dedicated `ci-runner` user, minimal sudoers |
| Script | Immutable (`chattr +i`), no args, no env, no stdin |
| Deployment | Atomic swap, config validation before restart, auto-rollback |
| Monitoring | Structured syslog, Slack notifications |
| Backup | Compressed tar archives, 3 retained, integrity-verifiable |
