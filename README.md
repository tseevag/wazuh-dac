# Wazuh Detection-as-Code (DaC) Pipeline

Automated deployment of Wazuh SIEM detection rules and decoders via a hardened CI/CD pipeline. Push XML rule changes to `main` and they deploy to the Wazuh manager automatically with validation, rollback, and Slack notifications.

## Architecture

```
GitHub Repo (wazuh-dac)
    │
    ├── rules/*.xml          ← Detection rules
    ├── decoders/*.xml       ← Log decoders
    │
    ▼ (push to main, **.xml)
GitHub Actions (self-hosted runner on Wazuh server)
    │
    ├── Verify script immutability (lsattr)
    ├── sudo /usr/local/bin/wazuh-deploy.sh
    │       │
    │       ├── Environment sanitization
    │       ├── git fetch + reset --hard (deterministic)
    │       ├── Sanity check (non-empty XML dirs)
    │       ├── Backup current config (timestamped)
    │       ├── rsync --delete rules + decoders
    │       ├── Fix ownership/permissions
    │       ├── Config validation (wazuh-analysisd -t)
    │       ├── Restart wazuh-manager
    │       ├── Health check (service + daemons)
    │       └── Auto-rollback on any failure
    │
    └── Slack notification (success/failure)
```

## Repository Structure

```
├── .github/workflows/
│   ├── integrate_rulesets.yml    # Deploy workflow (push to main)
│   └── check_rule_ids.yml       # Rule ID validation
├── rules/                        # Wazuh detection rules (XML)
├── decoders/                     # Wazuh log decoders (XML)
├── scripts/
│   ├── wazuh-deploy.sh           # Hardened deploy script (source)
│   └── install-deploy-script.sh  # Server installation script
└── check_rule_ids.py             # Rule ID uniqueness checker
```

## Documentation

For detailed guides, see the `docs/` directory:

- **[Setup Guide](docs/setup_guide.md)** — Step-by-step server deployment and pipeline configuration (start here)
- **[Architecture](docs/architecture.md)** — System architecture, data flow, and component descriptions
- **[Security](docs/security.md)** — Security model, threat mitigations, and control rationale
- **[Troubleshooting](docs/troubleshooting.md)** — Structured diagnostic procedures and resolution steps

## Security Controls

| Control | Implementation |
|---------|---------------|
| Script immutability | `chattr +i` on deploy script; workflow verifies before execution |
| No user input | Rejects arguments, redirects stdin from /dev/null |
| Environment sanitization | Unsets all inherited env vars, sets explicit PATH |
| Absolute paths | Every command uses full path; no `cd`, `pushd`, `popd` |
| Least privilege | `NOPASSWD:NOSETENV` sudoers; script only executable by root |
| Concurrency lock | `flock` prevents simultaneous deployments |
| Deterministic git | `fetch + reset --hard` instead of `pull` |
| Content validation | Refuses to deploy empty rule/decoder directories |
| Config validation | `wazuh-analysisd -t` before restart |
| Auto-rollback | Restores backup on config failure, restart failure, or health check failure |
| Structured logging | Syslog via `logger` (facility local6, tag wazuh-deploy) |
| Workflow permissions | `contents: read` only; no secrets passed to script |

## Deploy Script Phases

The script (`/usr/local/bin/wazuh-deploy.sh`) executes in this order:

1. **Environment Sanitization** — redirect stdin, unset all env vars, set PATH
2. **Pre-condition Checks** — reject args, verify root, verify repo structure
3. **Concurrency Lock** — `flock` on `/var/run/wazuh-deploy.lock`
4. **Git Fetch + Reset** — deterministic sync to `origin/main`
5. **Sanity Check** — verify XML files exist in rules/ and decoders/
6. **Backup** — timestamped copy of current production config
7. **Rsync** — sync decoders and rules with `--delete`
8. **Permissions** — `wazuh:wazuh`, files 640, dirs 750
9. **Config Test** — `wazuh-analysisd -t` (rollback if fails)
10. **Restart** — `systemctl restart wazuh-manager` (rollback if fails)
11. **Health Check** — verify service active + key daemons running (rollback if fails)
12. **Success Log** — `event=deploy_complete outcome=success`

## Backup Strategy

Backups are stored in `/var/ossec/backups/` with timestamps

```
/var/ossec/backups/
├── 2026-05-19T110639Z/      # Timestamped backup
├── 2026-05-20T090115Z/      # Another
├── 2026-05-20T143022Z/      # Newest
└── latest -> 2026-05-20T143022Z/   # Symlink to most recent
```

- Backup taken before every sync (captures current production state)
- `latest` symlink updated atomically after each backup
- Old backups pruned automatically (keeps last 3)
- Rollback uses the current run's backup directory

## Rollback Behavior

Auto-rollback triggers on:
- Config validation failure (`wazuh-analysisd -t` returns non-zero)
- Service restart failure (`systemctl restart` returns non-zero)
- Post-restart health check failure (service not active or daemons missing)

Rollback action:
1. `rsync -a --delete` from backup to production
2. Fix ownership (`wazuh:wazuh`)
3. Restart service with old config
4. Log rollback event to syslog

## Slack Notifications

The workflow sends Slack messages on deploy success or failure.

**Setup:**
1. Create a Slack Incoming Webhook (api.slack.com/apps → Incoming Webhooks)
2. Add repository secret: Settings → Secrets → `SLACK_WEBHOOK_URL`

**Success message:**
> ✅ SIEM Rules Deployed Successfully
> Commit, actor, branch, link to run

**Failure message:**
> 🚨 SIEM Rules Deployment FAILED
> Commit, actor, branch, link to run, syslog check hint

## Updating the Deploy Script

The script is protected with `chattr +i`. To update:

```bash
sudo chattr -i /usr/local/bin/wazuh-deploy.sh
sudo cp /path/to/new/wazuh-deploy.sh /usr/local/bin/wazuh-deploy.sh
sudo chown root:root /usr/local/bin/wazuh-deploy.sh
sudo chmod 0700 /usr/local/bin/wazuh-deploy.sh
sudo chattr +i /usr/local/bin/wazuh-deploy.sh
lsattr /usr/local/bin/wazuh-deploy.sh   # verify 'i' flag
```

## Workflow File

`.github/workflows/integrate_rulesets.yml`:

- Triggers on push to `main` when `**.xml` files change, or manual dispatch
- `permissions: contents: read` (minimum required)
- Pre-flight: verifies deploy script immutability via `lsattr`
- Deploy: `sudo /usr/local/bin/wazuh-deploy.sh` (no args, no env, no secrets)
- Notifications: Slack webhook on success/failure

## Syslog Integration

All deploy events are logged to syslog with:
- **Tag:** `wazuh-deploy`
- **Facility:** `local6`
- **Format:** structured key=value pairs

Filter with:
```bash
grep wazuh-deploy /var/log/messages | tail -20
```

Optional: route to dedicated file via rsyslog:
```bash
echo 'local6.*    /var/log/wazuh-deploy.log' | sudo tee /etc/rsyslog.d/wazuh-deploy.conf
sudo systemctl restart rsyslog
```

## Event Types in Logs

| Event | Meaning |
|-------|---------|
| `event=deploy_start phase=pull` | Git fetch started |
| `event=deploy_start phase=sync_decoders` | Decoder sync started |
| `event=deploy_start phase=sync_rules` | Rule sync started |
| `event=deploy_start phase=config_test` | Config validation started |
| `event=deploy_start phase=restart_service` | Service restart started |
| `event=deploy_complete outcome=success` | Deployment succeeded |
| `event=deploy_complete outcome=failure` | Deployment failed |
| `event=health_check outcome=success` | Post-restart health OK |
| `event=health_check outcome=failure` | Post-restart health failed |
| `event=rollback reason=*` | Auto-rollback triggered |
| `event=precondition_failed reason=*` | Pre-check failed |
| `event=immutable_check_failed` | Script immutability missing |

## Adding New Rules

1. Create/edit XML files in `rules/` or `decoders/`
2. Commit and push to a branch
3. Open a PR to `main`
4. On merge, the pipeline deploys automatically
5. If the rules are invalid, auto-rollback keeps Wazuh running

