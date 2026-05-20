#!/bin/bash
set -euo pipefail

# Readonly configuration variables
readonly REPO_DIR="/opt/wazuh-dac"
readonly TARGET_DIR="/var/ossec/etc"
readonly BACKUP_BASE="/var/ossec/actions-backups"
readonly GIT_BRANCH="main"
readonly SERVICE_NAME="wazuh-manager"
readonly LOG_TAG="actions-wazuh-deploy"
readonly LOG_FACILITY="local6"
readonly LOCK_FILE="/var/run/wazuh-deploy.lock"
readonly BACKUP_KEEP=2

###############################################################################
# Phase 1: Environment Sanitization
###############################################################################

# Redirect stdin from /dev/null — no external input accepted
exec < /dev/null

# Unset all inherited environment variables
while IFS='=' read -r var_name _; do
  unset "$var_name" 2>/dev/null || true
done < <(/usr/bin/env)

# Set explicit PATH after unsetting all inherited variables
PATH=/usr/bin:/usr/sbin

# Verify no residual inherited variables remain after sanitization
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

###############################################################################
# Phase 0: Shell Hardening & Configuration
###############################################################################

# Restrictive umask before any file operations
umask 0027

###############################################################################
# Logging Functions
###############################################################################

# log_entry() — sends structured key=value messages to syslog.
# Uses facility local6 and tag "wazuh-deploy" for easy filtering.
# Usage: log_entry "key1=value1 key2=value2 ..."
log_entry() {
  /usr/bin/logger -t "$LOG_TAG" -p "${LOG_FACILITY}.info" "$1"
}

# log_failure — records a deployment failure with truncated/sanitized stderr
# Usage: log_failure <exit_code> <phase> <stderr_content>
log_failure() {
  local exit_code=$1
  local phase=$2
  # Truncate to 256 chars and strip characters that could corrupt structured log
  local stderr_content
  stderr_content=$(printf '%s' "${3:0:256}" | /usr/bin/tr -d '\n"' | /usr/bin/tr -c '[:print:]' '?')
  /usr/bin/logger -t "$LOG_TAG" -p "${LOG_FACILITY}.err" \
    "event=deploy_complete outcome=failure exit_code=${exit_code} phase=${phase} stderr=[${stderr_content}]"
}

# rollback_from_backup — restores decoders/ and rules/ from the tar backup
# Usage: rollback_from_backup
rollback_from_backup() {
  /usr/bin/rm -rf "$TARGET_DIR/decoders" "$TARGET_DIR/rules"
  /usr/bin/tar -xzf "$BACKUP_FILE" --selinux -C "$TARGET_DIR" ./decoders ./rules
  /usr/bin/chown -R wazuh:wazuh "$TARGET_DIR/decoders" "$TARGET_DIR/rules"
}

###############################################################################
# Phase 2: Pre-condition Checks
###############################################################################

# Reject any command-line arguments
if [ $# -gt 0 ]; then
  log_entry "event=precondition_failed reason=args_passed user=root"
  exit 1
fi

# Verify running as root (EUID == 0)
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root (EUID=0). Current EUID=${EUID}." >&2
  log_entry "event=precondition_failed reason=not_root user=$(/usr/bin/id -un)"
  exit 1
fi

# Verify repository structure exists
if [ ! -d "$REPO_DIR/decoders" ] || [ ! -d "$REPO_DIR/rules" ]; then
  log_entry "event=precondition_failed reason=invalid_repo_structure"
  exit 1
fi

###############################################################################
# Fix #3: Concurrency lock — only one deployment at a time
###############################################################################

exec 9>"$LOCK_FILE"
if ! /usr/bin/flock -n 9; then
  log_entry "event=precondition_failed reason=concurrent_execution"
  exit 1
fi

###############################################################################
# Phase 3: Deployment Operations
###############################################################################

# Fix #5: Deterministic git fetch + reset instead of git pull
log_entry "event=deploy_start phase=pull"
stderr_output=$(/usr/bin/git -C "$REPO_DIR" fetch origin "$GIT_BRANCH" 2>&1) || {
  log_failure $? "pull" "$stderr_output"
  exit 2
}
stderr_output=$(/usr/bin/git -C "$REPO_DIR" reset --hard "origin/$GIT_BRANCH" 2>&1) || {
  log_failure $? "pull" "$stderr_output"
  exit 2
}
COMMIT_SHA=$(/usr/bin/git -C "$REPO_DIR" rev-parse HEAD)

# Sanity check — ensure repo has actual content before destructive sync
decoder_count=$(/usr/bin/find "$REPO_DIR/decoders" -name '*.xml' -type f | /usr/bin/wc -l)
rule_count=$(/usr/bin/find "$REPO_DIR/rules" -name '*.xml' -type f | /usr/bin/wc -l)
if [ "$decoder_count" -eq 0 ] || [ "$rule_count" -eq 0 ]; then
  log_entry "event=precondition_failed reason=empty_repo_content commit=$COMMIT_SHA decoders=$decoder_count rules=$rule_count"
  exit 1
fi

# Backup current config (compressed tar archive with atomic write)
BACKUP_TAR="ossec-etc-$(/usr/bin/date --utc '+%Y-%m-%dT%H%M%S').tar.gz"
BACKUP_FILE="${BACKUP_BASE}/${BACKUP_TAR}"
BACKUP_TMP="${BACKUP_BASE}/.backup.tar.gz.tmp"
/usr/bin/mkdir -p "$BACKUP_BASE"
stderr_output=$(/usr/bin/tar -czf "$BACKUP_TMP" --selinux -C "$TARGET_DIR" . 2>&1) || {
  /usr/bin/rm -f "$BACKUP_TMP"
  log_failure $? "backup" "$stderr_output"
  exit 2
}
# Atomic move from tmp to final name
/usr/bin/mv "$BACKUP_TMP" "$BACKUP_FILE"
# Update 'latest' symlink
/usr/bin/ln -sfn "$BACKUP_FILE" "${BACKUP_BASE}/latest.tar.gz"
# Prune old backups — keep only the most recent N archives
while IFS= read -r old_backup; do
  /usr/bin/rm -f "$old_backup"
done < <(/usr/bin/find "$BACKUP_BASE" -maxdepth 1 -name '*.tar.gz' -type f | /usr/bin/sort -r | /usr/bin/tail -n +$((BACKUP_KEEP + 1)))

# Sync decoders (copy to staging, then atomic rename-swap)
log_entry "event=deploy_start commit=$COMMIT_SHA phase=sync_decoders"
stderr_output=$( {
  /usr/bin/rm -rf "$TARGET_DIR/decoders.new" &&
  /usr/bin/cp -a "$REPO_DIR/decoders" "$TARGET_DIR/decoders.new" &&
  /usr/bin/mv "$TARGET_DIR/decoders" "$TARGET_DIR/decoders.old" &&
  /usr/bin/mv "$TARGET_DIR/decoders.new" "$TARGET_DIR/decoders" &&
  /usr/bin/rm -rf "$TARGET_DIR/decoders.old"
} 2>&1) || {
  # Recovery: if .new exists but swap failed, restore original
  [ -d "$TARGET_DIR/decoders.old" ] && /usr/bin/mv "$TARGET_DIR/decoders.old" "$TARGET_DIR/decoders"
  /usr/bin/rm -rf "$TARGET_DIR/decoders.new"
  log_failure $? "sync_decoders" "$stderr_output"
  exit 2
}

# Sync rules (copy to staging, then atomic rename-swap)
log_entry "event=deploy_start commit=$COMMIT_SHA phase=sync_rules"
stderr_output=$( {
  /usr/bin/rm -rf "$TARGET_DIR/rules.new" &&
  /usr/bin/cp -a "$REPO_DIR/rules" "$TARGET_DIR/rules.new" &&
  /usr/bin/mv "$TARGET_DIR/rules" "$TARGET_DIR/rules.old" &&
  /usr/bin/mv "$TARGET_DIR/rules.new" "$TARGET_DIR/rules" &&
  /usr/bin/rm -rf "$TARGET_DIR/rules.old"
} 2>&1) || {
  # Full rollback — decoders were already swapped, restore both from backup
  rollback_from_backup
  log_failure $? "sync_rules" "$stderr_output"
  exit 2
}

# Fix ownership & permissions
/usr/bin/chown -R wazuh:wazuh "$TARGET_DIR/decoders" "$TARGET_DIR/rules"
/usr/bin/find "$TARGET_DIR/decoders" "$TARGET_DIR/rules" -type f -exec /usr/bin/chmod 640 {} \;
/usr/bin/find "$TARGET_DIR/decoders" "$TARGET_DIR/rules" -type d -exec /usr/bin/chmod 750 {} \;

# Fix #6: Validate configuration before restart
log_entry "event=deploy_start commit=$COMMIT_SHA phase=config_test"
stderr_output=$(/var/ossec/bin/wazuh-analysisd -t 2>&1) || {
  log_failure $? "config_test" "$stderr_output"
  # Rollback on validation failure
  rollback_from_backup
  log_entry "event=rollback reason=config_test_failed commit=$COMMIT_SHA"
  exit 2
}

# Restart service
log_entry "event=deploy_start commit=$COMMIT_SHA phase=restart_service"
stderr_output=$(/usr/bin/systemctl restart "$SERVICE_NAME" 2>&1) || {
  log_failure $? "restart_service" "$stderr_output"
  # Rollback on restart failure
  rollback_from_backup
  /usr/bin/systemctl restart "$SERVICE_NAME" 2>/dev/null || true
  log_entry "event=rollback reason=restart_failed commit=$COMMIT_SHA"
  exit 2
}

###############################################################################
# Phase 4: Post-restart Health Validation
###############################################################################

readonly HEALTH_TIMEOUT=30
readonly HEALTH_INTERVAL=2

# Poll until service is active (up to HEALTH_TIMEOUT seconds)
health_elapsed=0
while [ "$health_elapsed" -lt "$HEALTH_TIMEOUT" ]; do
  if /usr/bin/systemctl is-active --quiet "$SERVICE_NAME"; then
    break
  fi
  /usr/bin/sleep "$HEALTH_INTERVAL"
  health_elapsed=$((health_elapsed + HEALTH_INTERVAL))
done

if ! /usr/bin/systemctl is-active --quiet "$SERVICE_NAME"; then
  log_entry "event=health_check outcome=failure reason=service_not_active timeout=${HEALTH_TIMEOUT}s commit=$COMMIT_SHA"
  rollback_from_backup
  /usr/bin/systemctl restart "$SERVICE_NAME" 2>/dev/null || true
  log_entry "event=rollback reason=health_check_failed commit=$COMMIT_SHA"
  exit 2
fi

# Poll until all key daemons are running (up to HEALTH_TIMEOUT seconds)
daemons_ok=false
health_elapsed=0
while [ "$health_elapsed" -lt "$HEALTH_TIMEOUT" ]; do
  all_running=true
  for daemon in wazuh-analysisd wazuh-remoted wazuh-syscheckd; do
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
  # Identify which daemon is missing for the log
  for daemon in wazuh-analysisd wazuh-remoted wazuh-syscheckd; do
    if ! /usr/bin/pgrep -x "$daemon" > /dev/null 2>&1; then
      log_entry "event=health_check outcome=failure reason=daemon_missing daemon=$daemon timeout=${HEALTH_TIMEOUT}s commit=$COMMIT_SHA"
    fi
  done
  rollback_from_backup
  /usr/bin/systemctl restart "$SERVICE_NAME" 2>/dev/null || true
  log_entry "event=rollback reason=daemon_missing commit=$COMMIT_SHA"
  exit 2
fi

log_entry "event=health_check outcome=success commit=$COMMIT_SHA"
