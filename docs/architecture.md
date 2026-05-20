# Wazuh Detection-as-Code: Architecture
<!-- Last updated: 2026-05-20 -->

## Navigation

[Setup Guide](setup_guide.md) | [Security](security.md) | [Troubleshooting](troubleshooting.md)

## What is Wazuh?

Wazuh is an open-source Security Information and Event Management (SIEM) platform. At its core, Wazuh collects log data from across your infrastructure, analyzes it in real time, and generates alerts when it detects suspicious activity. Think of it as a security analyst that never sleeps — continuously watching your systems for signs of compromise, misconfiguration, or policy violations.

### Key Concepts

**Agents** are lightweight processes installed on the machines you want to monitor (servers, workstations, cloud instances). Each agent collects logs, file integrity data, and system inventory from its host and forwards that telemetry to the central Wazuh manager for analysis.

**The Wazuh Manager** is the central server that receives data from all agents. It runs the analysis engine (`wazuh-analysisd`) which processes incoming events against a set of rules and decoders to determine whether an alert should be generated.

**Decoders** are XML definitions that teach Wazuh how to parse raw log lines into structured fields. For example, a decoder for SSH logs extracts the username, source IP, and authentication result from a syslog entry. Without the correct decoder, Wazuh cannot understand the log format.

**Rules** are XML definitions that describe conditions to match against decoded events. When a decoded event matches a rule's criteria (such as "five failed SSH logins from the same IP within 60 seconds"), Wazuh generates an alert with the rule's severity level and description. Rules can be simple single-event matches or complex correlations across multiple events.

### How They Work Together

```
Agent (on monitored host)
    │
    │  forwards logs
    ▼
Wazuh Manager
    │
    ├── Decoders: parse raw logs → structured fields
    │
    ├── Rules: match structured fields → generate alerts
    │
    └── Alerts → Dashboard, email, Slack, SOAR integrations
```

In this pipeline, we manage the rules and decoders as code in a Git repository. When you push changes to the repository, the pipeline automatically deploys them to the Wazuh manager, where they take effect on the next analysis cycle.

## Detection-as-Code Philosophy

Detection-as-Code is the practice of managing security detection logic (rules, decoders, and correlation policies) in version-controlled source files rather than editing them directly on a production server. It applies the same principles that software engineering uses for application code — version control, peer review, automated testing, and continuous deployment — to security operations.

### Why Not Just Edit Rules on the Server?

In a traditional workflow, an analyst SSH-es into the Wazuh manager, edits an XML rule file, and restarts the service. This approach has several problems:

- **No audit trail.** There is no record of who changed what, when, or why. If a rule breaks detection, you cannot easily identify or revert the change.
- **No peer review.** Mistakes go live immediately. A typo in a rule's regex can silence critical alerts with no one noticing until an incident is missed.
- **No testing before deployment.** The first validation happens on the production system. A malformed XML file can crash the analysis engine and take down all detection.
- **Configuration drift.** Over time, the production rules diverge from any documented baseline. Rebuilding the server or auditing the detection coverage becomes guesswork.
- **Single point of failure.** If the server's disk fails, all custom rules are lost unless someone remembered to back them up.

### How Detection-as-Code Solves This

By storing rules and decoders in a Git repository and deploying them through an automated pipeline:

- **Every change is tracked.** Git records who made the change, when, and the commit message explains why. You can diff any two points in history.
- **Peer review is enforced.** Pull requests require approval before merging to `main`. A second pair of eyes catches errors before they reach production.
- **Automated validation runs before deployment.** The CI pipeline checks XML syntax and rule ID uniqueness on every pull request. Invalid rules never reach the server.
- **Rollback is instant.** If a deployment causes problems, the pipeline's auto-rollback restores the previous known-good configuration. You can also revert a Git commit and redeploy.
- **The repository is the source of truth.** The production state always matches what is in `main`. There is no drift, and rebuilding the server is as simple as re-running the pipeline.
- **Collaboration scales.** Multiple analysts can work on rules in parallel using branches, without stepping on each other's changes.

This repository implements Detection-as-Code for Wazuh. The `rules/` and `decoders/` directories contain the detection logic, and the GitHub Actions pipeline handles validated, automated deployment to the Wazuh manager.

## Pipeline Components

The Detection-as-Code pipeline consists of five components working together to move rule changes from a developer's workstation to the production Wazuh manager safely and automatically.

### GitHub Repository

The repository (`wazuh-dac`) is the single source of truth for all custom detection rules and decoders. It stores:

- `rules/*.xml` — Custom Wazuh rule definitions (alert logic)
- `decoders/*.xml` — Custom decoder definitions (log parsing logic)
- `.github/workflows/` — CI/CD workflow definitions that automate validation and deployment
- `scripts/wazuh_deploy.sh` — The deploy script source (installed separately on the server)

The repository enforces change management through branch protection: all changes go through pull requests, receive peer review, and pass automated validation before merging to `main`.

### GitHub Actions Workflows

Two workflows automate the pipeline:

1. **PR Validation (`check_rule_ids.yml`)** — Runs on every pull request targeting `main`. Validates XML syntax and checks for rule ID conflicts before changes can be merged. This workflow runs on GitHub-hosted runners (`ubuntu-latest`) since it only needs to read and validate files.

2. **Deploy (`integrate_rulesets.yml`)** — Runs when changes to `*.xml` files are pushed to `main` (typically via a merged PR), or on manual dispatch. This workflow triggers the actual deployment to the Wazuh server. It runs on the self-hosted runner because it needs local access to the server.

### Self-Hosted Runner

The GitHub Actions runner agent is installed directly on the Wazuh manager server, running under the `ci-runner` user account. When the deploy workflow triggers, GitHub dispatches the job to this runner, which executes the deploy script locally via `sudo`. The runner has no elevated privileges of its own — it can only invoke the single deploy script as root, and cannot pass environment variables into that privileged context. See [GitHub Actions Self-Hosted Runner](#github-actions-self-hosted-runner) for a detailed explanation of why self-hosted is used and its security implications.

### Deploy Script (`wazuh_deploy.sh`)

The deploy script is the core of the deployment process. Installed at `/usr/local/bin/wazuh-deploy.sh` and protected with the immutable file attribute (`chattr +i`), it handles the entire deployment lifecycle:

- **Environment sanitization** — Unsets all inherited environment variables to prevent injection
- **Precondition checks** — Verifies root execution, repository structure, and no command-line arguments
- **Concurrency lock** — Uses `flock` to prevent simultaneous deployments
- **Git fetch + reset** — Pulls the latest `main` branch state deterministically (no `git pull`)
- **Sanity checks** — Ensures the repository contains actual rule and decoder files before proceeding
- **Backup** — Creates a compressed tar archive of the current production configuration
- **Atomic file sync** — Copies new files to a staging directory, then swaps them into place atomically
- **Permission enforcement** — Sets correct ownership (`wazuh:wazuh`) and permissions (640 files, 750 directories)
- **Configuration validation** — Runs `wazuh-analysisd -t` to verify the new rules parse correctly
- **Service restart** — Restarts the `wazuh-manager` service to load the new configuration
- **Health checks** — Polls until the service and all key daemons are confirmed running
- **Auto-rollback** — If validation, restart, or health checks fail, restores the backup and restarts

For security details on the deploy script, see [Security: Environment Sanitization](security.md#environment-sanitization) and [Security: Deterministic Git Strategy](security.md#deterministic-git-strategy-fetch--reset---hard).

### Wazuh Manager

The Wazuh manager is the destination for deployed rules and decoders. After a successful deployment, the manager's analysis engine (`wazuh-analysisd`) loads the new rule and decoder files from `/var/ossec/etc/rules/` and `/var/ossec/etc/decoders/`. From that point, all incoming events from agents are evaluated against the updated detection logic, and alerts fire according to the new rule definitions.

## End-to-End Data Flow

The following diagram shows the complete path a rule change takes from a developer's workstation to active detection on the Wazuh manager:

```
Developer Workstation          GitHub                    Wazuh Server
─────────────────────    ─────────────────────    ─────────────────────
                         
 git push (branch)  ───►  PR Created
                          ┌─────────────────┐
                          │ check_rule_ids   │
                          │ (ubuntu-latest)  │
                          │  • XML syntax    │
                          │  • ID conflicts  │
                          └────────┬────────┘
                                   │ pass
 Merge PR           ───►  Push to main
                          ┌─────────────────┐     ┌─────────────────┐
                          │ integrate_       │────►│ Self-hosted     │
                          │ rulesets.yml     │     │ Runner          │
                          └─────────────────┘     │ (ci-runner)     │
                                                  └────────┬────────┘
                                                           │ sudo
                                                  ┌────────▼────────┐
                                                  │ wazuh-deploy.sh │
                                                  │  • fetch+reset  │
                                                  │  • backup       │
                                                  │  • sync files   │
                                                  │  • validate     │
                                                  │  • restart      │
                                                  │  • health check │
                                                  └────────┬────────┘
                                                           │
                                                  ┌────────▼────────┐
                                                  │ Wazuh Manager   │
                                                  │ (rules active)  │
                                                  └─────────────────┘
```

## GitHub Actions Self-Hosted Runner

A GitHub Actions runner is the machine that executes your CI/CD workflow steps. GitHub offers two types: hosted runners and self-hosted runners.

### What is a Self-Hosted Runner?

A self-hosted runner is a machine you own and manage that registers with GitHub to receive and execute workflow jobs. You install the runner agent software on the machine, connect it to your repository, and GitHub dispatches jobs to it whenever a workflow triggers.

In this pipeline, the self-hosted runner is installed directly on the Wazuh manager server, running under the `ci-runner` user account.

### Why Self-Hosted Instead of GitHub-Hosted?

GitHub-hosted runners are ephemeral virtual machines managed by GitHub. They work well for building and testing code, but they cannot deploy to your Wazuh server because:

- **Network access.** GitHub-hosted runners have no network path to your internal Wazuh server. You would need to expose the server to the internet or set up complex tunneling.
- **Credentials management.** Deploying from an external runner requires storing SSH keys or other credentials as GitHub Secrets and transmitting them over the network — increasing the attack surface.
- **Local execution.** The deploy script needs to run locally on the Wazuh server (it uses `systemctl`, accesses local file paths, and restarts the local service). Running it remotely would require SSH and elevated privileges over the network.

A self-hosted runner on the Wazuh server eliminates these problems. The runner executes the deploy script locally via `sudo`, with no network credentials, no remote access, and no exposed ports.

### Security Implications

Running a self-hosted runner on a production security server requires careful controls:

- **Restricted workflow permissions.** The workflow runs with `contents: read` only — it cannot modify the repository, create releases, or access other GitHub resources.
- **No secrets passed to the script.** The deploy script receives no arguments, no environment variables, and no GitHub Secrets. It operates entirely from local state.
- **Dedicated unprivileged user.** The runner runs as `ci-runner`, a user with no shell login, no home directory access beyond the runner, and tightly scoped sudo permissions.
- **Sudo with NOSETENV.** The `ci-runner` user can only run one specific command (`/usr/local/bin/wazuh-deploy.sh`) as root, and `NOSETENV` prevents it from injecting environment variables into the privileged context.
- **Script immutability.** The deploy script is protected with `chattr +i` (immutable attribute), preventing modification even by root until the attribute is explicitly removed. The workflow verifies this attribute before every execution.
- **Environment sanitization.** The deploy script unsets all inherited environment variables on startup, preventing any injection from the runner's execution context.

These controls ensure that even if the runner process is compromised, the attacker's ability to affect the Wazuh server is severely limited. For a detailed explanation of each security control, see [Security: Security Philosophy](security.md#security-philosophy).

## Workflow Relationship

The pipeline uses two separate GitHub Actions workflows with distinct triggers, execution environments, and purposes. Understanding when each runs and what it validates is essential for working with the pipeline.

### PR Validation Workflow (`check_rule_ids.yml`)

**Triggers:** Runs on every pull request targeting the `main` branch, regardless of which files changed.

**Runs on:** GitHub-hosted runners (`ubuntu-latest`). These are ephemeral VMs managed by GitHub — they have no access to the Wazuh server.

**Purpose:** Catch errors before they reach production. This workflow acts as a gate: if it fails, the PR cannot be merged (when branch protection is configured).

**What it validates:**

1. **XML syntax** (`check-xml-syntax` job) — Uses `xmllint` to verify every `.xml` file in the repository is well-formed. A malformed XML file would crash the Wazuh analysis engine on deployment.
2. **Rule ID conflicts** (`check-rule-ids` job) — Runs `check_rule_ids.py` to ensure no two rules share the same ID. Duplicate IDs cause unpredictable behavior where one rule silently overrides another. This job depends on the syntax check passing first.

**Key characteristic:** This workflow only reads files and runs validation tools. It never deploys anything and has no access to the Wazuh server.

### Deploy Workflow (`integrate_rulesets.yml`)

**Triggers:** Runs on two conditions:
- **Push to `main`** when any `*.xml` file changes (typically from a merged PR)
- **Manual dispatch** (`workflow_dispatch`) for ad-hoc deployments

**Runs on:** The self-hosted runner on the Wazuh server, executing as the `ci-runner` user.

**Purpose:** Deploy validated rule and decoder changes to the production Wazuh manager.

**What it does:**

1. Invokes `sudo /usr/local/bin/wazuh-deploy.sh` which handles the full deployment lifecycle (fetch, backup, sync, validate, restart, health check)
2. Sends a Slack notification on success or failure with commit details and a link to the workflow run

**Key characteristic:** This workflow only runs after changes have already passed PR validation and been merged. It trusts that the content is syntactically valid (verified by the PR workflow) and focuses on safe deployment with rollback capability.

### How They Work Together

The two workflows form a validation-then-deploy pipeline:

1. A developer pushes a branch and opens a PR → **PR validation** runs and checks correctness
2. The team reviews the PR and approves it → merge is allowed only if validation passed
3. The PR is merged to `main` → **deploy workflow** triggers and pushes changes to production
4. If deployment fails → the deploy script automatically rolls back to the previous state

This separation means validation runs cheaply on GitHub's infrastructure (no server resources consumed), while deployment runs locally on the server where it has the access it needs. The PR workflow catches "will this break Wazuh?" errors; the deploy workflow handles "how do we safely apply this?"

## Server Directory Layout

The deploy script synchronizes two directories from the Git repository to the Wazuh manager's production configuration path. The following diagram shows how repository paths map to their production counterparts:

```
Repository (/opt/wazuh-dac/)          Production (/var/ossec/etc/)
────────────────────────────          ──────────────────────────────
├── rules/                    ──sync──►  ├── rules/
│   ├── local_rules.xml                  │   ├── local_rules.xml
│   └── *.xml                            │   └── *.xml
├── decoders/                 ──sync──►  ├── decoders/
│   └── local_decoder.xml               │   └── local_decoder.xml
└── scripts/                             
    └── wazuh_deploy.sh                  /usr/local/bin/wazuh-deploy.sh (installed)
                                         /var/ossec/actions-backups/ (backup archives)
```

Key paths on the Wazuh server:

| Path | Purpose |
|------|---------|
| `/opt/wazuh-dac/` | Local clone of the Git repository |
| `/var/ossec/etc/rules/` | Production rule files loaded by `wazuh-analysisd` |
| `/var/ossec/etc/decoders/` | Production decoder files loaded by `wazuh-analysisd` |
| `/usr/local/bin/wazuh-deploy.sh` | Installed deploy script (immutable via `chattr +i`) |
| `/var/ossec/actions-backups/` | Compressed backup archives of previous configurations |
| `/var/ossec/actions-backups/latest.tar.gz` | Symlink to the most recent backup archive |
| `/var/run/wazuh-deploy.lock` | Lock file used by `flock` to prevent concurrent deployments |

The `scripts/` directory in the repository contains the deploy script source, but it is not synced automatically. The script is installed manually to `/usr/local/bin/wazuh-deploy.sh` and protected with the immutable attribute. See [Security: Immutable Script Attribute](security.md#immutable-script-attribute-chattr-i) for the update procedure.

## Backup and Rollback Lifecycle

Before syncing new files, the deploy script creates a compressed tar archive of the entire `/var/ossec/etc/` directory. If any subsequent step fails (configuration validation, service restart, or health check), the script automatically restores from this backup.

### State Transitions

```
                    ┌──────────────┐
                    │ Deploy Start │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Create Backup│
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │  Sync Files  │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
              ┌─NO──┤ Config Valid? │
              │     └──────┬───────┘
              │            │ YES
              │     ┌──────▼───────┐
              │┌─NO─┤Restart OK?   │
              ││    └──────┬───────┘
              ││           │ YES
              ││    ┌──────▼───────┐
              ││┌NO─┤Health Check? │
              │││   └──────┬───────┘
              │││          │ YES
              │││   ┌──────▼───────┐
              │││   │   SUCCESS    │
              │││   └──────────────┘
              │││
              ▼▼▼
        ┌──────────────┐
        │   ROLLBACK   │
        │ • Restore    │
        │ • Fix perms  │
        │ • Restart    │
        │ • Log event  │
        └──────────────┘
```

### Backup Details

- **Archive format:** Compressed tar (`ossec-etc-YYYY-MM-DDTHHMMSS.tar.gz`)
- **Storage location:** `/var/ossec/actions-backups/`
- **Latest symlink:** `/var/ossec/actions-backups/latest.tar.gz` always points to the most recent archive
- **Retention policy:** Only the last 2 archives are kept (`BACKUP_KEEP=2`); older archives are pruned automatically
- **Atomic write:** The archive is written to a temporary file (`.backup.tar.gz.tmp`) and then moved to its final name, preventing partial backups from being used

### Rollback Triggers

The deploy script triggers an automatic rollback when any of these conditions occur:

1. **Configuration validation failure** — `wazuh-analysisd -t` reports that the new rules or decoders contain errors
2. **Service restart failure** — `systemctl restart wazuh-manager` exits with a non-zero status
3. **Health check failure** — The service does not become active within 30 seconds, or key daemons (`wazuh-analysisd`, `wazuh-remoted`, `wazuh-syscheckd`) are not running after restart

### Rollback Procedure

When triggered, the rollback performs these steps:

1. Remove the current (broken) `decoders/` and `rules/` directories from `/var/ossec/etc/`
2. Extract the backup archive, restoring `decoders/` and `rules/` to their pre-deployment state
3. Set ownership to `wazuh:wazuh` on the restored files
4. Attempt to restart the `wazuh-manager` service with the restored configuration
5. Log the rollback event to syslog with the reason and commit SHA

For manual rollback procedures (when auto-rollback is insufficient), see [Troubleshooting: Manual Rollback Procedures](troubleshooting.md#manual-rollback-procedures).

## Concurrency Model

The deploy script uses a file-based lock to ensure only one deployment runs at a time. This prevents race conditions where two simultaneous deployments could corrupt the production configuration or create inconsistent backup state.

### How flock Works

The script acquires an exclusive lock on `/var/run/wazuh-deploy.lock` using the `flock` system call:

```bash
exec 9>"$LOCK_FILE"
if ! /usr/bin/flock -n 9; then
  log_entry "event=precondition_failed reason=concurrent_execution"
  exit 1
fi
```

The `-n` flag makes the lock attempt non-blocking. If the lock is already held by another process, `flock` returns immediately with a failure status rather than waiting. The lock is held for the entire duration of the deployment (from precondition checks through health validation) and is automatically released when the script exits — whether it exits successfully, fails, or is killed.

### What Happens on Concurrent Attempts

When a second deployment is attempted while one is already running:

1. The second script opens the lock file and attempts to acquire an exclusive lock
2. `flock -n` fails immediately because the first script holds the lock
3. The second script logs `event=precondition_failed reason=concurrent_execution` to syslog
4. The second script exits with status code 1
5. The GitHub Actions workflow reports the job as failed

This is a deliberate design choice: deployments are serialized rather than queued. If two pushes to `main` happen in quick succession, the first triggers a deployment and the second fails. The failed workflow can be re-run manually once the first deployment completes, or the next push to `main` will trigger a fresh deployment that includes both sets of changes.

### Why Non-Blocking

A blocking lock (waiting until the lock is available) would be problematic because:

- The GitHub Actions runner has a job timeout. A blocked deployment would eventually be killed by the runner, potentially leaving the system in an inconsistent state.
- Silent queuing hides failures. If a deployment is blocked for minutes, the team should know immediately rather than discovering it later.
- The second deployment may be redundant. If both pushes modify the same files, only the latest state matters — and the next triggered deployment will pick it up.

### Lock Scope

The lock covers the entire deployment lifecycle: git fetch, backup creation, file sync, configuration validation, service restart, and health checks. This ensures that no other deployment can interfere at any point during the process. The lock file itself (`/var/run/wazuh-deploy.lock`) persists between deployments but carries no state — only the OS-level lock on the file descriptor matters.
