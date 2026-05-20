#!/bin/bash
# =============================================================================
# wazuh_deploy.sh — Automated Wazuh Rules & Decoders Deployment Script
# =============================================================================
#
# PURPOSE:
#   This script pulls the latest Wazuh detection rules and decoders from a Git
#   repository and deploys them to the Wazuh manager's configuration directory.
#   It includes backup, rollback, config validation, and health checks to ensure
#   the Wazuh manager remains operational after every deployment.
#
# WORKFLOW:
#   1. Sanitize the environment (remove inherited variables for security)
#   2. Verify preconditions (root user, repo exists, no concurrent runs)
#   3. Pull latest code from Git
#   4. Backup current live configuration
#   5. Sync new decoders and rules using atomic swap (rename-based)
#   6. Validate the new configuration with wazuh-analysisd
#   7. Restart the Wazuh manager service
#   8. Health-check: confirm service and key daemons are running
#   9. If anything fails after step 4, rollback to the backup
#
# USAGE:
#   Run as root with no arguments:
#     sudo /path/to/wazuh_deploy.sh
#
# =============================================================================

# "set -e"  = Exit immediately if any command fails (non-zero exit code)
# "set -u"  = Treat references to unset variables as errors
# "set -o pipefail" = If any command in a pipeline fails, the whole pipeline fails
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration Variables (readonly = cannot be changed later in the script)
# ---------------------------------------------------------------------------

# Where the Git repository is cloned on this server
readonly REPO_DIR="/opt/wazuh-dac"

# The Wazuh manager's configuration directory (where rules/decoders live)
readonly TARGET_DIR="/var/ossec/etc"

# Directory to store compressed backups of the current config before deploying
readonly BACKUP_BASE="/var/ossec/actions-backups"

# Which Git branch to pull from
readonly GIT_BRANCH="main"

# The systemd service name for the Wazuh manager
readonly SERVICE_NAME="wazuh-manager"

# Tag used when writing to syslog (so you can filter logs easily)
readonly LOG_TAG="actions-wazuh-deploy"

# Syslog facility — "local6" is a custom facility often used for app logs
readonly LOG_FACILITY="local6"

# Lock file path — used to prevent two instances of this script running at once
readonly LOCK_FILE="/var/run/wazuh-deploy.lock"

# How many backup archives to keep (older ones get deleted)
readonly BACKUP_KEEP=2

###############################################################################
# Phase 1: Environment Sanitization
# ---------------------------------------------------------------------------
# WHY: When this script runs (e.g., from cron or a CI runner), it may inherit
# environment variables from the parent process. Some of those could be
# malicious or unexpected (e.g., LD_PRELOAD, PATH hijacking). We wipe
# everything and set only what we need.
###############################################################################

# Close stdin — this script should never read interactive input
# "exec < /dev/null" redirects stdin to /dev/null (empty input)
exec < /dev/null

# Loop through every environment variable and unset it.
# "/usr/bin/env" prints all current env vars in "KEY=VALUE" format.
# "IFS='='" splits each line on '=' so $var_name gets the key.
# "2>/dev/null || true" suppresses errors for read-only vars we can't unset.
while IFS='=' read -r var_name _; do
  unset "$var_name" 2>/dev/null || true
done < <(/usr/bin/env)

# Now set a minimal, safe PATH — only standard system binary directories
PATH=/usr/bin:/usr/sbin

# Verify that no unexpected variables survived the cleanup.
# We allow a whitelist of standard bash built-in variables.
# If anything else remains, it could indicate tampering — abort.
while IFS='=' read -r var_name _; do
  case "$var_name" in
    # These are standard bash/system variables that are always present
    PATH|BASHOPTS|BASH_VERSINFO|BASH_VERSION|SHELLOPTS|UID|EUID|PPID|IFS|PWD|OLDPWD|_|TERM|SHLVL|BASH|SHELL)
      ;;
    *)
      # Unexpected variable found — log a security alert and exit
      /usr/bin/logger -t "$LOG_TAG" -p auth.alert "event=precondition_failed reason=env_contamination var=$var_name"
      exit 1
      ;;
  esac
done < <(/usr/bin/env)

###############################################################################
# Phase 0: Shell Hardening
###############################################################################

# Set a restrictive file creation mask:
# 0027 means: owner=full access, group=read+execute, others=no access
# Any files created by this script will have permissions like 640 (rw-r-----)
# Any directories will have permissions like 750 (rwxr-x---)
umask 0027

###############################################################################
# Logging Functions
# ---------------------------------------------------------------------------
# These functions write structured log messages to syslog. You can view them
# with: journalctl -t actions-wazuh-deploy
###############################################################################

# log_entry() — Write an informational log message to syslog
# Usage: log_entry "event=deploy_start phase=pull"
log_entry() {
  # "-t" sets the tag, "-p" sets facility.severity
  /usr/bin/logger -t "$LOG_TAG" -p "${LOG_FACILITY}.info" "$1"
}

# log_failure() — Write an error log message with details about what failed
# Arguments:
#   $1 = exit code of the failed command
#   $2 = which phase failed (e.g., "pull", "backup", "sync_decoders")
#   $3 = stderr output from the failed command
log_failure() {
  local exit_code=$1
  local phase=$2

  # Truncate stderr to 256 characters max (avoid flooding syslog)
  # "tr -d '\n\"'" removes newlines and double quotes (which break log parsing)
  # "tr -c '[:print:]' '?'" replaces non-printable characters with '?'
  local stderr_content
  stderr_content=$(printf '%s' "${3:0:256}" | /usr/bin/tr -d '\n"' | /usr/bin/tr -c '[:print:]' '?')

  /usr/bin/logger -t "$LOG_TAG" -p "${LOG_FACILITY}.err" \
    "event=deploy_complete outcome=failure exit_code=${exit_code} phase=${phase} stderr=[${stderr_content}]"
}

# rollback_from_backup() — Restore decoders/ and rules/ from the backup archive
# ---------------------------------------------------------------------------
# SAFETY: This function extracts to a temporary directory FIRST. Only after
# confirming the extraction succeeded does it replace the live directories.
# This prevents the catastrophic scenario where we delete live dirs but the
# backup extraction fails (leaving us with nothing).
rollback_from_backup() {
  # Guard: if no backup file is set or it doesn't exist, we can't rollback
  if [ -z "$BACKUP_FILE" ] || [ ! -e "$BACKUP_FILE" ]; then
    log_entry "event=rollback outcome=skipped reason=no_backup_file"
    return 1
  fi

  # Create a temporary directory to extract into
  local rollback_tmp="$TARGET_DIR/.rollback_tmp"
  /usr/bin/rm -rf "$rollback_tmp"
  /usr/bin/mkdir -p "$rollback_tmp"

  # Try to extract decoders/ and rules/ from the backup into the temp dir
  # "--selinux" preserves SELinux security labels on extracted files
  # "-C" changes to the specified directory before extracting
  # If extraction fails, the live directories remain untouched
  if ! /usr/bin/tar -xzf "$BACKUP_FILE" --selinux -C "$rollback_tmp" ./decoders ./rules 2>/dev/null; then
    log_entry "event=rollback outcome=failure reason=extract_failed backup=$BACKUP_FILE"
    /usr/bin/rm -rf "$rollback_tmp"
    return 1
  fi

  # Extraction succeeded — now it's safe to replace the live directories
  # "rm -rf" forcefully removes directories and all their contents
  /usr/bin/rm -rf "$TARGET_DIR/decoders" "$TARGET_DIR/rules"

  # Move the extracted directories from temp into the live location
  /usr/bin/mv "$rollback_tmp/decoders" "$TARGET_DIR/decoders"
  /usr/bin/mv "$rollback_tmp/rules" "$TARGET_DIR/rules"

  # Clean up the temporary directory
  /usr/bin/rm -rf "$rollback_tmp"

  # Fix ownership: wazuh user/group must own these files for the service to read them
  # "-R" means recursive (apply to all files and subdirectories)
  /usr/bin/chown -R wazuh:wazuh "$TARGET_DIR/decoders" "$TARGET_DIR/rules"
}

###############################################################################
# Phase 2: Pre-condition Checks
# ---------------------------------------------------------------------------
# Verify the environment is correct before doing anything destructive.
###############################################################################

# This script takes no arguments — reject if any are passed
if [ $# -gt 0 ]; then
  log_entry "event=precondition_failed reason=args_passed user=root"
  exit 1
fi

# Must run as root (EUID=0) because we need to write to /var/ossec and restart services
# "$EUID" is a bash built-in that holds the effective user ID (0 = root)
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root (EUID=0). Current EUID=${EUID}." >&2
  log_entry "event=precondition_failed reason=not_root user=$(/usr/bin/id -un)"
  exit 1
fi

# Verify the Git repo has the expected directory structure
# "-d" tests if a directory exists
if [ ! -d "$REPO_DIR/decoders" ] || [ ! -d "$REPO_DIR/rules" ]; then
  log_entry "event=precondition_failed reason=invalid_repo_structure"
  exit 1
fi

###############################################################################
# Concurrency Lock
# ---------------------------------------------------------------------------
# Prevent multiple instances of this script from running simultaneously.
# Uses a file lock (flock) — if another instance holds the lock, we exit.
###############################################################################

# Open file descriptor 9 pointing to the lock file
# "exec 9>" opens the file for writing on FD 9 (doesn't truncate if using flock)
exec 9>"$LOCK_FILE"

# Try to acquire an exclusive lock without waiting ("-n" = non-blocking)
# If another process already holds the lock, flock returns non-zero and we exit
if ! /usr/bin/flock -n 9; then
  log_entry "event=precondition_failed reason=concurrent_execution"
  exit 1
fi

###############################################################################
# Phase 3: Deployment Operations
###############################################################################

# --- Step 1: Pull latest code from Git ---
# We use "fetch + reset --hard" instead of "git pull" because:
#   - "git pull" can fail if there are local changes or merge conflicts
#   - "fetch + reset --hard" always forces the local repo to match remote exactly
#   - This is a deployment target, not a development environment — we want determinism

log_entry "event=deploy_start phase=pull"

# Fetch the latest commits from the remote for our branch
# "-C" tells git to operate in the specified directory
# "2>&1" redirects stderr to stdout so we can capture all output
stderr_output=$(/usr/bin/git -C "$REPO_DIR" fetch origin "$GIT_BRANCH" 2>&1) || {
  log_failure $? "pull" "$stderr_output"
  exit 2
}

# Force the local branch to exactly match the remote branch
# "--hard" discards any local changes (this is intentional for a deploy target)
stderr_output=$(/usr/bin/git -C "$REPO_DIR" reset --hard "origin/$GIT_BRANCH" 2>&1) || {
  log_failure $? "pull" "$stderr_output"
  exit 2
}

# Record the current commit hash for logging/auditing
COMMIT_SHA=$(/usr/bin/git -C "$REPO_DIR" rev-parse HEAD)

# --- Step 2: Sanity check — make sure the repo actually has content ---
# This prevents deploying an empty or broken repo that would wipe out all rules.
# "find ... -name '*.xml' -type f" finds all XML files (regular files only)
# "wc -l" counts the number of lines (one file path per line = file count)
decoder_count=$(/usr/bin/find "$REPO_DIR/decoders" -name '*.xml' -type f | /usr/bin/wc -l)
rule_count=$(/usr/bin/find "$REPO_DIR/rules" -name '*.xml' -type f | /usr/bin/wc -l)

if [ "$decoder_count" -eq 0 ] || [ "$rule_count" -eq 0 ]; then
  log_entry "event=precondition_failed reason=empty_repo_content commit=$COMMIT_SHA decoders=$decoder_count rules=$rule_count"
  exit 1
fi

# --- Step 3: Backup current live configuration ---
# We only backup if the live directories actually exist. If they're already
# missing (e.g., from a previous failed deploy), we don't want to overwrite
# a good backup with an archive of an empty/broken state.

if [ -d "$TARGET_DIR/decoders" ] && [ -d "$TARGET_DIR/rules" ]; then
  # Generate a timestamped filename for the backup
  # "date --utc '+%Y-%m-%dT%H%M%S'" produces something like "2026-05-20T102718"
  BACKUP_TAR="ossec-etc-$(/usr/bin/date --utc '+%Y-%m-%dT%H%M%S').tar.gz"
  BACKUP_FILE="${BACKUP_BASE}/${BACKUP_TAR}"
  BACKUP_TMP="${BACKUP_BASE}/.backup.tar.gz.tmp"

  # Create the backup directory if it doesn't exist yet
  # "-p" means don't error if it already exists, and create parent dirs too
  /usr/bin/mkdir -p "$BACKUP_BASE"

  # Create a compressed tar archive of the entire /var/ossec/etc directory
  # "-c" = create, "-z" = gzip compress, "-f" = output filename
  # "--selinux" = preserve SELinux security labels in the archive
  # "-C" = change to this directory first (so paths in archive are relative)
  # "." = archive everything in the current directory
  # We write to a .tmp file first (atomic write pattern)
  stderr_output=$(/usr/bin/tar -czf "$BACKUP_TMP" --selinux -C "$TARGET_DIR" . 2>&1) || {
    # If tar fails, clean up the partial temp file and exit
    /usr/bin/rm -f "$BACKUP_TMP"
    log_failure $? "backup" "$stderr_output"
    exit 2
  }

  # Atomically rename the temp file to the final name
  # This ensures we never have a half-written backup file
  /usr/bin/mv "$BACKUP_TMP" "$BACKUP_FILE"

  # Update the "latest.tar.gz" symlink to point to this new backup
  # "-s" = symbolic link, "-f" = overwrite if exists, "-n" = don't dereference existing symlink
  /usr/bin/ln -sfn "$BACKUP_FILE" "${BACKUP_BASE}/latest.tar.gz"

  # Delete old backups, keeping only the N most recent (defined by BACKUP_KEEP)
  # "find" lists all ossec-etc-*.tar.gz files (real files, not symlinks)
  # "sort -r" sorts them in reverse order (newest first, because timestamps sort lexicographically)
  # "tail -n +3" skips the first 2 (BACKUP_KEEP) and outputs the rest (old ones to delete)
  while IFS= read -r old_backup; do
    /usr/bin/rm -f "$old_backup"
  done < <(/usr/bin/find "$BACKUP_BASE" -maxdepth 1 -name 'ossec-etc-*.tar.gz' -type f | /usr/bin/sort -r | /usr/bin/tail -n +$((BACKUP_KEEP + 1)))

  # Clean up any backups from an older version of this script that used a different naming convention
  /usr/bin/find "$BACKUP_BASE" -maxdepth 1 -name 'wazuh-deploy-*.tar.gz' -type f -delete

else
  # Live directories are missing — don't create a backup of a broken state
  log_entry "event=backup_skipped reason=missing_target_dirs commit=$COMMIT_SHA"

  # Try to use the existing "latest" backup for rollback purposes
  BACKUP_FILE="${BACKUP_BASE}/latest.tar.gz"
  if [ ! -e "$BACKUP_FILE" ]; then
    # No backup exists at all — this is a fresh deploy scenario
    # We can still proceed, but rollback won't be possible if something fails
    log_entry "event=precondition_failed reason=no_backup_available commit=$COMMIT_SHA"
    BACKUP_FILE=""
  fi
fi

# --- Step 4: Sync decoders from repo to live directory ---
# We use an "atomic swap" pattern:
#   1. Copy new content to a staging directory (decoders.new)
#   2. Rename the current live directory to .old (if it exists)
#   3. Rename the staging directory to the live name
#   4. Delete the .old directory
# This minimizes the window where the live directory is in an inconsistent state.

log_entry "event=deploy_start commit=$COMMIT_SHA phase=sync_decoders"
stderr_output=$( {
  # Remove any leftover staging directory from a previous failed run
  /usr/bin/rm -rf "$TARGET_DIR/decoders.new" &&

  # Remove any leftover .old directory from a previous failed run
  /usr/bin/rm -rf "$TARGET_DIR/decoders.old" &&

  # Copy the repo's decoders directory to a staging location
  # "-a" = archive mode (preserves permissions, ownership, timestamps, symlinks)
  /usr/bin/cp -a "$REPO_DIR/decoders" "$TARGET_DIR/decoders.new" &&

  # If the current live directory exists, move it aside (rename is atomic on same filesystem)
  if [ -d "$TARGET_DIR/decoders" ]; then
    /usr/bin/mv "$TARGET_DIR/decoders" "$TARGET_DIR/decoders.old"
  fi &&

  # Move the staging directory into place as the new live directory
  /usr/bin/mv "$TARGET_DIR/decoders.new" "$TARGET_DIR/decoders" &&

  # Clean up the old directory (no longer needed since we have a backup)
  /usr/bin/rm -rf "$TARGET_DIR/decoders.old"
} 2>&1) || {
  # ERROR RECOVERY: If the swap failed partway through, try to restore the old directory
  [ -d "$TARGET_DIR/decoders.old" ] && /usr/bin/mv "$TARGET_DIR/decoders.old" "$TARGET_DIR/decoders"
  /usr/bin/rm -rf "$TARGET_DIR/decoders.new"
  log_failure $? "sync_decoders" "$stderr_output"
  exit 2
}

# --- Step 5: Sync rules from repo to live directory (same pattern as decoders) ---

log_entry "event=deploy_start commit=$COMMIT_SHA phase=sync_rules"
stderr_output=$( {
  # Remove any leftover staging directory from a previous failed run
  /usr/bin/rm -rf "$TARGET_DIR/rules.new" &&

  # Remove any leftover .old directory from a previous failed run
  /usr/bin/rm -rf "$TARGET_DIR/rules.old" &&

  # Copy the repo's rules directory to a staging location
  /usr/bin/cp -a "$REPO_DIR/rules" "$TARGET_DIR/rules.new" &&

  # If the current live directory exists, move it aside
  if [ -d "$TARGET_DIR/rules" ]; then
    /usr/bin/mv "$TARGET_DIR/rules" "$TARGET_DIR/rules.old"
  fi &&

  # Move the staging directory into place as the new live directory
  /usr/bin/mv "$TARGET_DIR/rules.new" "$TARGET_DIR/rules" &&

  # Clean up the old directory
  /usr/bin/rm -rf "$TARGET_DIR/rules.old"
} 2>&1) || {
  # ERROR RECOVERY: Decoders were already swapped successfully, so we need a full
  # rollback (restore both decoders and rules from the backup archive)
  rollback_from_backup
  log_failure $? "sync_rules" "$stderr_output"
  exit 2
}

# --- Step 6: Fix file ownership and permissions ---
# Wazuh requires its config files to be owned by the "wazuh" user/group
# and have restrictive permissions (no world-readable)

# Set ownership recursively on both directories
/usr/bin/chown -R wazuh:wazuh "$TARGET_DIR/decoders" "$TARGET_DIR/rules"

# Set file permissions to 640 (owner: read+write, group: read, others: none)
# "-type f" matches only regular files (not directories)
# "-exec chmod 640 {} \;" runs chmod on each matched file
/usr/bin/find "$TARGET_DIR/decoders" "$TARGET_DIR/rules" -type f -exec /usr/bin/chmod 640 {} \;

# Set directory permissions to 750 (owner: full, group: read+execute, others: none)
# Directories need "execute" permission to allow traversal (cd into them)
/usr/bin/find "$TARGET_DIR/decoders" "$TARGET_DIR/rules" -type d -exec /usr/bin/chmod 750 {} \;

# --- Step 7: Validate the new configuration ---
# Run wazuh-analysisd in test mode ("-t") to check if the rules/decoders parse correctly.
# This catches syntax errors BEFORE we restart the service (which would cause downtime).

log_entry "event=deploy_start commit=$COMMIT_SHA phase=config_test"
stderr_output=$(/var/ossec/bin/wazuh-analysisd -t 2>&1) || {
  log_failure $? "config_test" "$stderr_output"
  # Config is invalid — rollback to the previous known-good state
  rollback_from_backup
  log_entry "event=rollback reason=config_test_failed commit=$COMMIT_SHA"
  exit 2
}

# --- Step 8: Restart the Wazuh manager service ---
# The new rules/decoders are in place and validated — restart to load them.

log_entry "event=deploy_start commit=$COMMIT_SHA phase=restart_service"
stderr_output=$(/usr/bin/systemctl restart "$SERVICE_NAME" 2>&1) || {
  log_failure $? "restart_service" "$stderr_output"
  # Restart failed — rollback and try to restart again with the old config
  rollback_from_backup
  /usr/bin/systemctl restart "$SERVICE_NAME" 2>/dev/null || true
  log_entry "event=rollback reason=restart_failed commit=$COMMIT_SHA"
  exit 2
}

###############################################################################
# Phase 4: Post-restart Health Validation
# ---------------------------------------------------------------------------
# After restarting, we verify the service is actually running and healthy.
# If it's not, we rollback and restart with the old config.
###############################################################################

# How long to wait (seconds) before giving up on health checks
readonly HEALTH_TIMEOUT=30

# How often to check (seconds) between each poll
readonly HEALTH_INTERVAL=2

# --- Check 1: Is the systemd service active? ---
# Poll every HEALTH_INTERVAL seconds until the service reports "active"
# or we exceed HEALTH_TIMEOUT seconds.

health_elapsed=0
while [ "$health_elapsed" -lt "$HEALTH_TIMEOUT" ]; do
  # "systemctl is-active --quiet" returns 0 if service is running, non-zero otherwise
  if /usr/bin/systemctl is-active --quiet "$SERVICE_NAME"; then
    break
  fi
  /usr/bin/sleep "$HEALTH_INTERVAL"
  health_elapsed=$((health_elapsed + HEALTH_INTERVAL))
done

# If we exited the loop without the service being active, it's a failure
if ! /usr/bin/systemctl is-active --quiet "$SERVICE_NAME"; then
  log_entry "event=health_check outcome=failure reason=service_not_active timeout=${HEALTH_TIMEOUT}s commit=$COMMIT_SHA"
  rollback_from_backup
  /usr/bin/systemctl restart "$SERVICE_NAME" 2>/dev/null || true
  log_entry "event=rollback reason=health_check_failed commit=$COMMIT_SHA"
  exit 2
fi

# --- Check 2: Are all critical Wazuh daemons running? ---
# Even if systemd says the service is "active", individual daemons inside
# the Wazuh manager might have crashed. We check for the three essential ones:
#   - wazuh-analysisd: Processes and correlates security events
#   - wazuh-remoted: Handles communication with Wazuh agents
#   - wazuh-syscheckd: File integrity monitoring daemon

daemons_ok=false
health_elapsed=0
while [ "$health_elapsed" -lt "$HEALTH_TIMEOUT" ]; do
  all_running=true

  for daemon in wazuh-analysisd wazuh-remoted wazuh-syscheckd; do
    # "pgrep -x" looks for a process with an exact name match
    # If the daemon isn't found, mark as not all running
    if ! /usr/bin/pgrep -x "$daemon" > /dev/null 2>&1; then
      all_running=false
      break
    fi
  done

  if [ "$all_running" = true ]; then
    daemons_ok=true
    break
  fi

  /usr/bin/sleep "$HEALTH_INTERVAL"
  health_elapsed=$((health_elapsed + HEALTH_INTERVAL))
done

if [ "$daemons_ok" = false ]; then
  # Log which specific daemon(s) failed to start
  for daemon in wazuh-analysisd wazuh-remoted wazuh-syscheckd; do
    if ! /usr/bin/pgrep -x "$daemon" > /dev/null 2>&1; then
      log_entry "event=health_check outcome=failure reason=daemon_missing daemon=$daemon timeout=${HEALTH_TIMEOUT}s commit=$COMMIT_SHA"
    fi
  done

  # Rollback and attempt to restart with the previous config
  rollback_from_backup
  /usr/bin/systemctl restart "$SERVICE_NAME" 2>/dev/null || true
  log_entry "event=rollback reason=daemon_missing commit=$COMMIT_SHA"
  exit 2
fi

# =============================================================================
# SUCCESS — All checks passed. The new rules and decoders are live.
# =============================================================================
log_entry "event=health_check outcome=success commit=$COMMIT_SHA"
