#!/bin/bash
# =============================================================================
# install_wazuh_deploy.sh — Pre-flight Checker for wazuh_deploy.sh
# =============================================================================
#
# PURPOSE:
#   Verifies that a Wazuh manager server is correctly set up to run the
#   wazuh_deploy.sh deployment script. Checks system tools, Wazuh installation,
#   deploy script presence/permissions/immutability, repository state, and
#   creates the backup directory if missing.
#
#   Both the deploy script and the Git repository are placed manually.
#   This script only verifies and reports — it does not install or clone.
#
# USAGE:
#   sudo bash install_wazuh_deploy.sh
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration — must match what wazuh_deploy.sh expects
# =============================================================================

REPO_URL="https://github.com/tseevag/wazuh-dac.git"
REPO_DIR="/opt/wazuh-dac"
GIT_BRANCH="main"
WAZUH_BASE="/var/ossec"
BACKUP_BASE="${WAZUH_BASE}/actions-backups"
SERVICE_NAME="wazuh-manager"
DEPLOY_SCRIPT="/usr/local/bin/wazuh_deploy.sh"

# =============================================================================
# Output Helpers
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
print_fail() { echo -e "${RED}[✗]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

print_header() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

FAIL_COUNT=0

# =============================================================================
# Phase 1: System Prerequisites
# =============================================================================

check_root() {
  if [ "$EUID" -ne 0 ]; then
    print_fail "Must be run as root"
    exit 1
  fi
  print_ok "Running as root"
}

check_os() {
  if [ ! -f /etc/os-release ]; then
    print_fail "Cannot determine OS — /etc/os-release not found"
    ((FAIL_COUNT++)) || true
    return
  fi
  source /etc/os-release
  print_ok "OS: $PRETTY_NAME"
}

check_commands() {
  print_info "Checking required tools..."
  local -A tools=(
    [git]="pull rules repository"
    [tar]="backup and restore archives"
    [flock]="concurrency locking"
    [logger]="syslog output"
    [systemctl]="service management"
    [pgrep]="daemon health checks"
  )
  for cmd in "${!tools[@]}"; do
    if command -v "$cmd" &>/dev/null; then
      print_ok "$cmd (${tools[$cmd]})"
    else
      print_fail "$cmd is NOT installed (${tools[$cmd]})"
      ((FAIL_COUNT++)) || true
    fi
  done
}

# =============================================================================
# Phase 2: Wazuh Manager
# =============================================================================

check_wazuh() {
  print_info "Checking Wazuh manager..."

  if [ ! -d "$WAZUH_BASE" ]; then
    print_fail "Wazuh not installed — $WAZUH_BASE not found"
    ((FAIL_COUNT++)) || true
    return
  fi
  print_ok "Wazuh directory: $WAZUH_BASE"

  if [ ! -d "${WAZUH_BASE}/etc" ]; then
    print_fail "Config directory missing: ${WAZUH_BASE}/etc"
    ((FAIL_COUNT++)) || true
    return
  fi
  print_ok "Config directory: ${WAZUH_BASE}/etc"

  if [ ! -x "${WAZUH_BASE}/bin/wazuh-analysisd" ]; then
    print_fail "wazuh-analysisd binary not found or not executable"
    ((FAIL_COUNT++)) || true
    return
  fi
  print_ok "wazuh-analysisd binary present"

  # Test config parsing
  if "${WAZUH_BASE}/bin/wazuh-analysisd" -t &>/dev/null; then
    print_ok "Config validation passed (wazuh-analysisd -t)"
  else
    print_warn "Config validation failed — current config may have issues"
  fi

  # Service status
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_ok "Service is running: $SERVICE_NAME"
  else
    print_warn "Service is NOT running: $SERVICE_NAME"
  fi

  # User and group
  if id -u wazuh &>/dev/null; then
    print_ok "User 'wazuh' exists"
  else
    print_fail "User 'wazuh' does not exist"
    ((FAIL_COUNT++)) || true
  fi

  if getent group wazuh &>/dev/null; then
    print_ok "Group 'wazuh' exists"
  else
    print_fail "Group 'wazuh' does not exist"
    ((FAIL_COUNT++)) || true
  fi
}

# =============================================================================
# Phase 3: Deploy Script
# =============================================================================

check_deploy_script() {
  print_info "Checking deploy script: $DEPLOY_SCRIPT"

  # Existence
  if [ ! -f "$DEPLOY_SCRIPT" ]; then
    print_fail "Not found: $DEPLOY_SCRIPT"
    print_info "  → Place it manually: cp wazuh_deploy.sh $DEPLOY_SCRIPT"
    ((FAIL_COUNT++)) || true
    return
  fi
  print_ok "Script exists"

  # Executable
  if [ ! -x "$DEPLOY_SCRIPT" ]; then
    print_fail "Not executable"
    print_info "  → Fix: chmod 700 $DEPLOY_SCRIPT"
    ((FAIL_COUNT++)) || true
  else
    print_ok "Executable"
  fi

  # Ownership
  local owner group
  owner=$(stat -c '%U' "$DEPLOY_SCRIPT")
  group=$(stat -c '%G' "$DEPLOY_SCRIPT")
  if [ "$owner" = "root" ] && [ "$group" = "root" ]; then
    print_ok "Ownership: root:root"
  else
    print_fail "Ownership: $owner:$group (expected root:root)"
    print_info "  → Fix: chown root:root $DEPLOY_SCRIPT"
    ((FAIL_COUNT++)) || true
  fi

  # Permissions
  local perms
  perms=$(stat -c '%a' "$DEPLOY_SCRIPT")
  if [ "$perms" = "700" ]; then
    print_ok "Permissions: 700"
  elif [ "$perms" = "750" ] || [ "$perms" = "755" ]; then
    print_warn "Permissions: $perms (recommended: 700)"
    print_info "  → Fix: chmod 700 $DEPLOY_SCRIPT"
  else
    print_fail "Permissions: $perms (must be 700)"
    print_info "  → Fix: chmod 700 $DEPLOY_SCRIPT"
    ((FAIL_COUNT++)) || true
  fi

  # Immutable attribute (chattr +i)
  if command -v lsattr &>/dev/null; then
    local attrs
    attrs=$(lsattr "$DEPLOY_SCRIPT" 2>/dev/null | awk '{print $1}')
    if [[ "$attrs" == *"i"* ]]; then
      print_ok "Immutable flag set (chattr +i)"
    else
      print_warn "Immutable flag NOT set"
      print_info "  → Recommended: chattr +i $DEPLOY_SCRIPT"
    fi
  fi

  # Syntax
  if bash -n "$DEPLOY_SCRIPT" 2>/dev/null; then
    print_ok "Syntax check passed"
  else
    print_fail "Syntax errors detected"
    ((FAIL_COUNT++)) || true
  fi
}

# =============================================================================
# Phase 4: Repository
# =============================================================================

check_repo() {
  print_info "Checking repository: $REPO_DIR"

  if [ ! -d "$REPO_DIR/.git" ]; then
    print_fail "Repository not found: $REPO_DIR"
    print_info "  → Clone it: git clone --branch $GIT_BRANCH $REPO_URL $REPO_DIR"
    ((FAIL_COUNT++)) || true
    return
  fi
  print_ok "Repository exists"

  # Structure
  if [ -d "$REPO_DIR/decoders" ] && [ -d "$REPO_DIR/rules" ]; then
    print_ok "Structure: decoders/ and rules/ present"
  else
    print_fail "Missing decoders/ or rules/ directories"
    print_info "  → Check branch: git -C $REPO_DIR checkout $GIT_BRANCH"
    ((FAIL_COUNT++)) || true
    return
  fi

  # Content
  local decoder_count rule_count
  decoder_count=$(find "$REPO_DIR/decoders" -name '*.xml' -type f 2>/dev/null | wc -l)
  rule_count=$(find "$REPO_DIR/rules" -name '*.xml' -type f 2>/dev/null | wc -l)
  if [ "$decoder_count" -gt 0 ] && [ "$rule_count" -gt 0 ]; then
    print_ok "Content: $decoder_count decoder(s), $rule_count rule file(s)"
  else
    print_warn "Content looks empty (decoders=$decoder_count, rules=$rule_count)"
  fi
}

# =============================================================================
# Phase 5: Backup Directory
# =============================================================================

check_backup_dir() {
  if [ -d "$BACKUP_BASE" ]; then
    print_ok "Backup directory exists: $BACKUP_BASE"

    # Verify permissions
    local dir_owner dir_perms
    dir_owner=$(stat -c '%U:%G' "$BACKUP_BASE")
    dir_perms=$(stat -c '%a' "$BACKUP_BASE")
    if [ "$dir_owner" = "root:wazuh" ] && [ "$dir_perms" = "750" ]; then
      print_ok "Backup directory permissions: $dir_owner $dir_perms"
    else
      print_warn "Backup directory: $dir_owner mode $dir_perms (expected root:wazuh 750)"
      print_info "  → Fixing permissions..."
      chown root:wazuh "$BACKUP_BASE"
      chmod 750 "$BACKUP_BASE"
      print_ok "Permissions corrected"
    fi
  else
    print_info "Creating backup directory: $BACKUP_BASE"
    mkdir -p "$BACKUP_BASE"
    chown root:wazuh "$BACKUP_BASE"
    chmod 750 "$BACKUP_BASE"
    print_ok "Backup directory created: root:wazuh 750"
  fi
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║       Wazuh DAC — Pre-flight Check                         ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

  print_header "Phase 1: System Prerequisites"
  check_root
  check_os
  check_commands

  print_header "Phase 2: Wazuh Manager"
  check_wazuh

  print_header "Phase 3: Deploy Script"
  check_deploy_script

  print_header "Phase 4: Repository"
  check_repo

  print_header "Phase 5: Backup Directory"
  check_backup_dir

  # ─── Result ─────────────────────────────────────────────────────────────────
  echo ""
  if [ "$FAIL_COUNT" -gt 0 ]; then
    print_fail "$FAIL_COUNT check(s) failed — fix the issues above and re-run"
    exit 1
  fi

  print_ok "All checks passed. Environment is ready."
  echo ""
  print_info "Deploy script:  $DEPLOY_SCRIPT"
  print_info "Repository:     $REPO_DIR"
  print_info "Backups:        $BACKUP_BASE"
  print_info "Run manually:   sudo $DEPLOY_SCRIPT"
  print_info "Deploy logs:    journalctl -t actions-wazuh-deploy"
  echo ""
}

main
