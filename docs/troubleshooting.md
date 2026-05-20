# Wazuh Detection-as-Code: Troubleshooting Guide
<!-- Last updated: 2026-05-20 -->

## Navigation

[Setup Guide](setup_guide.md) | [Architecture](architecture.md) | [Security](security.md)

## How to Use This Guide

This guide is organized by observable symptom. When a deployment fails or the pipeline behaves unexpectedly:

1. Identify the symptom you are experiencing (error message, workflow failure, or unexpected behavior).
2. Find the matching entry below under [Issues by Symptom](#issues-by-symptom).
3. Run the diagnostic commands to confirm the root cause.
4. Follow the resolution steps to fix the issue.

All deploy events are logged to syslog with the tag `actions-wazuh-deploy` and facility `local6`. The deploy script exits with code **1** for precondition failures and code **2** for operation failures. If the script triggers an automatic rollback, it restores the previous configuration and restarts the service before exiting.

If you cannot resolve the issue using this guide, see the [Escalation](#escalation) section at the bottom.

## Issues by Symptom

### Deploy Script Precondition Failures

**Symptom:** The GitHub Actions workflow fails immediately with exit code 1. The workflow log shows the deploy script exited before performing any sync or restart operations.

**Likely cause:** The deploy script performs several precondition checks before starting deployment. A failure here means one of the following conditions was not met:

- The script was invoked with arguments (it accepts none)
- The script is not running as root (EUID ≠ 0)
- The repository directory structure is missing (`/opt/wazuh-dac/rules/` or `/opt/wazuh-dac/decoders/` does not exist)
- Environment contamination was detected (unexpected inherited environment variables)
- The repository contains no XML files in `rules/` or `decoders/` after git fetch

**Diagnostic commands:**

**On the Wazuh server, as root:**

```bash
grep "precondition_failed" /var/log/messages | grep "actions-wazuh-deploy" | tail -5
```

**Expected output:**

```
May 20 14:30:22 wazuh-server actions-wazuh-deploy: event=precondition_failed reason=not_root user=ci-runner
```

or

```
May 20 14:30:22 wazuh-server actions-wazuh-deploy: event=precondition_failed reason=invalid_repo_structure
```

or

```
May 20 14:30:22 wazuh-server actions-wazuh-deploy: event=precondition_failed reason=empty_repo_content commit=abc1234 decoders=0 rules=3
```

**On the Wazuh server, as root:**

```bash
ls -la /opt/wazuh-dac/rules/*.xml /opt/wazuh-dac/decoders/*.xml
```

**Resolution steps:**

1. Check the `reason` field in the syslog entry to identify which precondition failed.
2. For `not_root`: Verify the sudoers configuration grants the `ci-runner` user passwordless root access to the deploy script. See [Setup Guide: Phase 4](setup_guide.md#phase-4-configure-sudoers).
3. For `invalid_repo_structure`: Ensure `/opt/wazuh-dac/` exists with `rules/` and `decoders/` subdirectories. Re-clone the repository if needed.
4. For `empty_repo_content`: Verify the repository on the `main` branch contains XML files in both `rules/` and `decoders/` directories.
5. For `env_contamination`: Check that the sudoers entry uses `NOSETENV` to prevent environment variable injection. See [Security: Sudoers Configuration](security.md#sudoers-configuration-nopasswdnosetenv).
6. For `args_passed`: Ensure the workflow calls the script without any arguments (`sudo /usr/local/bin/wazuh-deploy.sh` with no trailing arguments).

---

### Configuration Validation Failures

**Symptom:** The workflow fails with exit code 2. Syslog shows `phase=config_test` in the failure entry. The deploy script automatically rolled back to the previous configuration.

**Likely cause:** After syncing new rules and decoders to the production directory, the script runs `wazuh-analysisd -t` to validate the configuration. This fails when:

- An XML rule or decoder file has syntax errors
- A rule references a non-existent decoder or rule group
- A rule ID conflicts with an existing built-in rule
- File permissions prevent `wazuh-analysisd` from reading the configuration

**Diagnostic commands:**

**On the Wazuh server, as root:**

```bash
grep "actions-wazuh-deploy" /var/log/messages | grep -E "config_test|rollback" | tail -5
```

**Expected output:**

```
May 20 14:31:05 wazuh-server actions-wazuh-deploy: event=deploy_complete outcome=failure exit_code=2 phase=config_test stderr=[ERROR: (1226): Error reading XML file '/var/ossec/etc/rules/local_rules.xml': XMLERR: Attribute 'level' required.]
May 20 14:31:05 wazuh-server actions-wazuh-deploy: event=rollback reason=config_test_failed commit=abc1234
```

**On the Wazuh server, as root:**

```bash
/var/ossec/bin/wazuh-analysisd -t 2>&1 | head -20
```

> ⚠️ **Pitfall:** After a rollback, running `wazuh-analysisd -t` will validate the restored (working) configuration, not the broken one. To test the new rules, you need to manually copy them back from the repository and run the validation again.

**Resolution steps:**

1. Examine the `stderr` field in the syslog entry for the specific validation error.
2. Fix the XML syntax or rule logic error in your local repository.
3. Run the rule ID checker locally before pushing:

**On your local machine:**

```bash
python check_rule_ids.py
```

4. Commit the fix and push to trigger a new deployment.

---

### Service Restart Failures

**Symptom:** The workflow fails with exit code 2. Syslog shows `phase=restart_service` in the failure entry. The deploy script automatically rolled back and attempted to restart with the previous configuration.

**Likely cause:** After configuration validation passes, the script restarts the `wazuh-manager` service. This can fail when:

- The Wazuh manager binary is corrupted or missing
- System resources (memory, disk) are exhausted
- A dependent service (e.g., `wazuh-db`) is in a failed state
- SELinux is blocking the service from starting

**Diagnostic commands:**

**On the Wazuh server, as root:**

```bash
grep "actions-wazuh-deploy" /var/log/messages | grep -E "restart_service|rollback" | tail -5
```

**Expected output:**

```
May 20 14:32:10 wazuh-server actions-wazuh-deploy: event=deploy_complete outcome=failure exit_code=2 phase=restart_service stderr=[Job for wazuh-manager.service failed because the control process exited with error code.]
May 20 14:32:10 wazuh-server actions-wazuh-deploy: event=rollback reason=restart_failed commit=abc1234
```

**On the Wazuh server, as root:**

```bash
systemctl status wazuh-manager
```

```bash
journalctl -u wazuh-manager --since "5 minutes ago" --no-pager | tail -30
```

```bash
df -h /var/ossec
```

**Resolution steps:**

1. Check `systemctl status wazuh-manager` for the immediate error.
2. Review `journalctl` output for detailed failure messages from the Wazuh manager process.
3. Verify disk space is available on the `/var/ossec` partition.
4. Check if the rollback restored service operation. If the service is running after rollback, the issue is likely in the new configuration (even though `wazuh-analysisd -t` passed).
5. If the service is not running even after rollback, this indicates a system-level issue unrelated to the deployment. Check SELinux denials:

**On the Wazuh server, as root:**

```bash
ausearch -m avc -ts recent | grep wazuh
```

6. If the system-level issue persists, see [Escalation](#escalation).

---

### Health Check Failures

**Symptom:** The workflow fails with exit code 2. Syslog shows `event=health_check outcome=failure`. The service restarted successfully but one or more key daemons did not come up within the 30-second timeout.

**Likely cause:** After a successful restart, the script verifies that the `wazuh-manager` service is active and that three key daemons are running: `wazuh-analysisd`, `wazuh-remoted`, and `wazuh-syscheckd`. A health check failure means:

- The service started but crashed shortly after
- One or more daemons failed to initialize (e.g., due to a configuration issue not caught by `-t`)
- The server is under heavy load and daemons took longer than 30 seconds to start

**Diagnostic commands:**

**On the Wazuh server, as root:**

```bash
grep "actions-wazuh-deploy" /var/log/messages | grep "health_check" | tail -5
```

**Expected output:**

```
May 20 14:33:45 wazuh-server actions-wazuh-deploy: event=health_check outcome=failure reason=daemon_missing daemon=wazuh-analysisd timeout=30s commit=abc1234
```

**On the Wazuh server, as root:**

```bash
systemctl is-active wazuh-manager
```

```bash
pgrep -la "wazuh-analysisd|wazuh-remoted|wazuh-syscheckd"
```

```bash
tail -50 /var/ossec/logs/ossec.log
```

**Resolution steps:**

1. Identify which daemon is missing from the syslog `daemon=` field.
2. Check `/var/ossec/logs/ossec.log` for errors from the specific daemon.
3. If the issue is load-related (all daemons eventually start but take longer than 30 seconds), this may be a transient issue. Re-run the workflow to attempt deployment again.
4. If a specific daemon consistently fails to start, check its configuration:

**On the Wazuh server, as root:**

```bash
/var/ossec/bin/wazuh-analysisd -t 2>&1
```

5. After rollback, verify the system recovered:

**On the Wazuh server, as root:**

```bash
systemctl is-active wazuh-manager && pgrep -x wazuh-analysisd && pgrep -x wazuh-remoted && pgrep -x wazuh-syscheckd && echo "All healthy"
```

---

### Runner Connectivity Issues

**Symptom:** The GitHub Actions workflow is queued but never starts, or it starts but fails with "Unable to connect" or "Self-hosted runner is offline" messages in the Actions UI.

**Likely cause:** The self-hosted runner on the Wazuh server is not connected to GitHub. This can happen when:

- The runner service (`actions.runner.*`) is stopped or crashed
- The server lost network connectivity or a firewall is blocking outbound HTTPS
- The runner's authentication token expired (rare, tokens are long-lived)
- The server was rebooted and the runner service did not start automatically

**Diagnostic commands:**

**On the Wazuh server, as ci-runner:**

```bash
cd ~/actions-runner && ./svc.sh status
```

**Expected output (healthy):**

```
● actions.runner.your-org-your-repo.your-runner.service - GitHub Actions Runner
   Active: active (running) since Mon 2026-05-20 09:00:00 UTC
```

**Expected output (unhealthy):**

```
● actions.runner.your-org-your-repo.your-runner.service - GitHub Actions Runner
   Active: inactive (dead)
```

**On the Wazuh server, as root:**

```bash
curl -sf https://github.com -o /dev/null && echo "GitHub reachable" || echo "GitHub NOT reachable"
```

**Resolution steps:**

1. Check if the runner service is running. If stopped, start it:

**On the Wazuh server, as ci-runner:**

```bash
cd ~/actions-runner && ./svc.sh start
```

2. If the service fails to start, check its logs:

**On the Wazuh server, as ci-runner:**

```bash
journalctl -u "actions.runner.*" --since "10 minutes ago" --no-pager | tail -30
```

3. Verify network connectivity to GitHub. If blocked, check firewall rules:

**On the Wazuh server, as root:**

```bash
firewall-cmd --list-all
```

4. If the runner token has expired, re-register the runner following [Setup Guide: Phase 6](setup_guide.md#phase-6-install-the-github-actions-self-hosted-runner).
5. To ensure the runner starts on boot:

**On the Wazuh server, as ci-runner:**

```bash
cd ~/actions-runner && sudo ./svc.sh install ci-runner
```

---

### Git Fetch Failures

**Symptom:** The workflow fails with exit code 2. Syslog shows `phase=pull` in the failure entry. No files were synced and no rollback was needed (the failure occurred before any changes were made to production).

**Likely cause:** The deploy script runs `git fetch origin main` followed by `git reset --hard origin/main` to synchronize the local repository. This fails when:

- The server cannot reach GitHub (network or DNS issue)
- The deploy key or credentials for the repository are missing or expired
- The `/opt/wazuh-dac/` directory is not a valid git repository
- Disk space is insufficient for the git operation
- The remote repository was deleted or the branch was renamed

**Diagnostic commands:**

**On the Wazuh server, as root:**

```bash
grep "actions-wazuh-deploy" /var/log/messages | grep "phase=pull" | tail -5
```

**Expected output:**

```
May 20 14:28:30 wazuh-server actions-wazuh-deploy: event=deploy_complete outcome=failure exit_code=2 phase=pull stderr=[fatal: Could not read from remote repository. Please make sure you have the correct access rights and the repository exists.]
```

**On the Wazuh server, as root:**

```bash
git -C /opt/wazuh-dac remote -v
```

```bash
git -C /opt/wazuh-dac fetch origin main 2>&1
```

```bash
ssh -T git@github.com 2>&1
```

**Resolution steps:**

1. Check the `stderr` field in the syslog entry for the specific git error.
2. Verify the repository remote URL is correct with `git remote -v`.
3. Test SSH connectivity to GitHub. If using a deploy key, verify it exists and has correct permissions:

**On the Wazuh server, as root:**

```bash
ls -la /root/.ssh/id_* 2>/dev/null || echo "No SSH keys found"
```

4. If the deploy key expired or was removed from the repository settings, generate a new one and add it to the repository. See [Setup Guide: Phase 1](setup_guide.md#phase-1-create-the-github-repository).
5. If the issue is DNS or network related:

**On the Wazuh server, as root:**

```bash
host github.com
```

6. Verify disk space is available:

**On the Wazuh server, as root:**

```bash
df -h /opt/wazuh-dac
```

---

### Concurrent Execution Blocks

**Symptom:** The workflow fails with exit code 1. Syslog shows `event=precondition_failed reason=concurrent_execution`. A deployment was already in progress when a second one was attempted.

**Likely cause:** The deploy script uses `flock` on `/var/run/wazuh-deploy.lock` to ensure only one deployment runs at a time. If a deployment is already in progress (or a previous deployment crashed without releasing the lock), subsequent attempts will fail immediately. See [Architecture: Concurrency Model](architecture.md#concurrency-model) for details on how this mechanism works.

**Diagnostic commands:**

**On the Wazuh server, as root:**

```bash
grep "concurrent_execution" /var/log/messages | grep "actions-wazuh-deploy" | tail -3
```

**Expected output:**

```
May 20 14:35:00 wazuh-server actions-wazuh-deploy: event=precondition_failed reason=concurrent_execution
```

**On the Wazuh server, as root:**

```bash
fuser /var/run/wazuh-deploy.lock 2>/dev/null && echo "Lock is held by a running process" || echo "No process holds the lock"
```

**Resolution steps:**

1. If a deployment is genuinely in progress, wait for it to complete. The lock is released automatically when the script exits.
2. If the lock is stale (no process holds it but the file exists), the lock file itself is not the problem — `flock` locks are released when the file descriptor is closed. Simply re-run the workflow.
3. If `fuser` shows a process holding the lock, check what it is:

**On the Wazuh server, as root:**

```bash
fuser -v /var/run/wazuh-deploy.lock
```

4. If the holding process is a zombie or stuck deployment, terminate it:

**On the Wazuh server, as root:**

```bash
kill $(fuser /var/run/wazuh-deploy.lock 2>/dev/null)
```

5. After the lock is released, re-run the GitHub Actions workflow.
6. To prevent concurrent triggers, consider enabling GitHub Actions concurrency controls in the workflow file to queue deployments instead of running them in parallel.

## Manual Rollback Procedures

The deploy script automatically rolls back when it detects a failure during configuration validation, service restart, or health checks. Manual rollback is needed in two situations:

1. **Auto-rollback itself failed** — the script attempted to restore the backup but encountered an error (e.g., corrupted backup archive, disk full, permission issue).
2. **Changes were made outside the pipeline** — someone manually edited files in `/var/ossec/etc/rules/` or `/var/ossec/etc/decoders/` and the system is now in a broken state with no pipeline-triggered backup covering those changes.

### When Auto-Rollback Handles It

You do **not** need to perform manual rollback if syslog shows a successful rollback event:

**On the Wazuh server, as root:**

```bash
grep "event=rollback" /var/log/messages | grep "actions-wazuh-deploy" | tail -3
```

**Expected output:**

```
May 20 14:31:05 wazuh-server actions-wazuh-deploy: event=rollback reason=config_test_failed commit=abc1234
```

If you see a rollback entry and the service is running, the auto-rollback succeeded. No manual intervention is needed.

### Step-by-Step Manual Rollback

#### 1. Identify the latest backup

Backups are stored in `/var/ossec/actions-backups/` with the naming pattern `ossec-etc-YYYY-MM-DDTHHMMSS.tar.gz`. A symlink at `latest.tar.gz` points to the most recent backup.

**On the Wazuh server, as root:**

```bash
ls -la /var/ossec/actions-backups/latest.tar.gz
```

**Expected output:**

```
lrwxrwxrwx 1 root root 68 May 20 14:30 /var/ossec/actions-backups/latest.tar.gz -> /var/ossec/actions-backups/ossec-etc-2026-05-20T143022.tar.gz
```

If the `latest.tar.gz` symlink is missing or broken, list available backups and choose the most recent one:

**On the Wazuh server, as root:**

```bash
ls -lt /var/ossec/actions-backups/ossec-etc-*.tar.gz
```

#### 2. Inspect the backup contents (optional but recommended)

Before restoring, verify the backup contains the expected files:

**On the Wazuh server, as root:**

```bash
tar -tzf /var/ossec/actions-backups/latest.tar.gz | head -20
```

**Expected output:**

```
./decoders/
./decoders/local_decoder.xml
./rules/
./rules/local_rules.xml
./rules/1001-ssh-rules-tuned.xml
...
```

#### 3. Remove the current broken configuration

**On the Wazuh server, as root:**

```bash
rm -rf /var/ossec/etc/decoders /var/ossec/etc/rules
```

#### 4. Restore from backup

**On the Wazuh server, as root:**

```bash
tar -xzf /var/ossec/actions-backups/latest.tar.gz -C /var/ossec/etc ./decoders ./rules
```

#### 5. Fix ownership and permissions

**On the Wazuh server, as root:**

```bash
chown -R wazuh:wazuh /var/ossec/etc/decoders /var/ossec/etc/rules
find /var/ossec/etc/decoders /var/ossec/etc/rules -type f -exec chmod 640 {} \;
find /var/ossec/etc/decoders /var/ossec/etc/rules -type d -exec chmod 750 {} \;
```

#### 6. Validate the restored configuration

**On the Wazuh server, as root:**

```bash
/var/ossec/bin/wazuh-analysisd -t
```

**Expected output:**

```
wazuh-analysisd: Configuration verification completed without errors. Exiting.
```

#### 7. Restart the Wazuh manager

**On the Wazuh server, as root:**

```bash
systemctl restart wazuh-manager
```

#### 8. Verify the service is healthy

Follow the full checklist in [Verifying System Health After Failure](#verifying-system-health-after-failure) below.

> ⚠️ **Pitfall:** If you restore from a backup that was created before a required rule change, the restored configuration will be valid but may be missing detection coverage. After manual rollback, re-run the pipeline by pushing a commit to `main` to re-deploy the latest rules from the repository.

---

## Verifying System Health After Failure

After any deployment failure (whether auto-rollback or manual rollback was performed), run through this checklist to confirm the Wazuh manager is operating correctly. All checks should pass before considering the system recovered.

### Health Check Checklist

#### 1. Service is active

**On the Wazuh server, as root:**

```bash
systemctl is-active wazuh-manager
```

**Expected output:**

```
active
```

#### 2. All key daemons are running

The three critical daemons are `wazuh-analysisd` (rule processing), `wazuh-remoted` (agent communication), and `wazuh-syscheckd` (file integrity monitoring).

**On the Wazuh server, as root:**

```bash
pgrep -la "wazuh-analysisd|wazuh-remoted|wazuh-syscheckd"
```

**Expected output:**

```
12345 /var/ossec/bin/wazuh-analysisd
12346 /var/ossec/bin/wazuh-remoted
12347 /var/ossec/bin/wazuh-syscheckd
```

All three daemons must appear in the output. If any are missing, check `/var/ossec/logs/ossec.log` for errors.

#### 3. Configuration validates cleanly

**On the Wazuh server, as root:**

```bash
/var/ossec/bin/wazuh-analysisd -t
```

**Expected output:**

```
wazuh-analysisd: Configuration verification completed without errors. Exiting.
```

#### 4. No recent errors in the Wazuh log

**On the Wazuh server, as root:**

```bash
grep -i "error\|critical" /var/ossec/logs/ossec.log | tail -10
```

Review the output for any errors that occurred after the rollback. Transient startup messages are normal, but persistent errors indicate an unresolved issue.

#### 5. Rules and decoders directories have correct ownership

**On the Wazuh server, as root:**

```bash
stat -c '%U:%G %a %n' /var/ossec/etc/rules /var/ossec/etc/decoders
```

**Expected output:**

```
wazuh:wazuh 750 /var/ossec/etc/rules
wazuh:wazuh 750 /var/ossec/etc/decoders
```

#### 6. Agents are connected (if applicable)

**On the Wazuh server, as root:**

```bash
/var/ossec/bin/agent_control -l | head -10
```

Verify that agents show a status of `Active`. If agents show `Disconnected`, wait 1–2 minutes for them to reconnect after the service restart.

#### 7. Combined one-liner health check

For a quick pass/fail verification of the core components:

**On the Wazuh server, as root:**

```bash
systemctl is-active wazuh-manager && pgrep -x wazuh-analysisd > /dev/null && pgrep -x wazuh-remoted > /dev/null && pgrep -x wazuh-syscheckd > /dev/null && echo "ALL HEALTHY" || echo "HEALTH CHECK FAILED"
```

**Expected output:**

```
active
ALL HEALTHY
```

If any check fails, refer to the relevant symptom entry in [Issues by Symptom](#issues-by-symptom) above for targeted diagnostics.

---

## Escalation

### When to Escalate

Escalate to the infrastructure or security team if any of the following criteria are met:

1. **Manual rollback fails** — you attempted the manual rollback procedure and the system still cannot start or validate configuration.
2. **Service will not start regardless of configuration** — both the new and the backed-up configuration fail to start the service, indicating a system-level issue (corrupted binaries, disk failure, SELinux blocking).
3. **Repeated auto-rollback on valid rules** — the pipeline consistently fails and rolls back even though the rules pass local validation with `wazuh-analysisd -t` and the rule ID checker.
4. **Security concern** — you suspect unauthorized changes were made to the production configuration, the deploy script, or the sudoers file.
5. **Data loss** — backup archives are missing, corrupted, or the backup directory (`/var/ossec/actions-backups/`) is empty when it should contain recent backups.
6. **Runner compromise** — the self-hosted runner is behaving unexpectedly, running unknown processes, or the runner token may have been exposed.

### Information to Gather Before Escalating

Collect the following information before contacting the team. This accelerates diagnosis and avoids back-and-forth:

**On the Wazuh server, as root:**

```bash
# 1. Recent deploy log entries
grep "actions-wazuh-deploy" /var/log/messages | tail -20 > /tmp/deploy-logs.txt

# 2. Service status
systemctl status wazuh-manager > /tmp/service-status.txt 2>&1

# 3. Journal entries for the service
journalctl -u wazuh-manager --since "30 minutes ago" --no-pager > /tmp/journal.txt 2>&1

# 4. Wazuh application log
tail -100 /var/ossec/logs/ossec.log > /tmp/ossec-log.txt

# 5. Disk space
df -h /var/ossec /opt/wazuh-dac > /tmp/disk-space.txt

# 6. Backup inventory
ls -la /var/ossec/actions-backups/ > /tmp/backup-inventory.txt

# 7. SELinux denials (if applicable)
ausearch -m avc -ts recent 2>/dev/null | grep wazuh > /tmp/selinux.txt
```

**Expected output:**

The commands above write diagnostic files to `/tmp/`. Attach these files to your escalation ticket or message.

### Escalation Channels

| Severity | Channel | Response Time |
|----------|---------|---------------|
| Service down, agents disconnected | Direct message to on-call engineer + incident ticket | Immediate |
| Pipeline broken but service running | Team channel or ticket | Within business hours |
| Security concern | Security team direct + incident ticket | Immediate |

### What to Include in the Escalation

- **Summary:** One sentence describing the problem (e.g., "Wazuh manager will not start after manual rollback; all backups appear corrupted").
- **Timeline:** When the issue started and what actions were taken.
- **Diagnostic files:** The files collected above (`/tmp/deploy-logs.txt`, `/tmp/service-status.txt`, etc.).
- **What was tried:** List the troubleshooting steps already attempted from this guide.
- **Current state:** Is the service running? Are agents connected? Is the pipeline blocked?

See [Architecture: Backup and Rollback Lifecycle](architecture.md#backup-and-rollback-lifecycle) for context on how the backup system works, and [Security: Immutable Script Attribute](security.md#immutable-script-attribute-chattr-i) if the issue involves the deploy script itself.
