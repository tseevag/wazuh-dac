#!/bin/bash
set -euo pipefail

# Secure environment
export PATH="/usr/sbin:/usr/bin:/bin"
unset LD_PRELOAD LD_LIBRARY_PATH PYTHONPATH

# Commands
MKDIR='/usr/bin/mkdir'
RM='/usr/bin/rm'
CP='/usr/bin/cp'
RSYNC='/usr/bin/rsync'
CHOWN='/usr/bin/chown'
FIND='/usr/bin/find'
SYSTEMCTL='/usr/bin/systemctl'

# REPO_DIR="/opt/wazuh-config-repo"
TARGET_DIR="/var/ossec/etc"
BACKUP_DIR="/var/ossec/etc.bak"

# mkdir -p "$REPO_DIR"
# mkdir -p "$TARGET_DIR"
$MKDIR -p "$BACKUP_DIR"

# 1. Pull latest config into staging
# cd "$REPO_DIR"
# /usr/bin/git pull origin main

# 2. Backup current config
$RM -rf "$BACKUP_DIR"
$CP -r "$TARGET_DIR" "$BACKUP_DIR"

# 3. Copy new rules into place
$RSYNC -av --delete \
  "$REPO_DIR/decoders/" "$TARGET_DIR/decoders/"

$RSYNC -av --delete \
  "$REPO_DIR/rules/" "$TARGET_DIR/rules/"

# 4. Fix ownership & permissionS
$CHOWN -R wazuh:wazuh "$TARGET_DIR/decoders" "$TARGET_DIR/rules"
$FIND "$TARGET_DIR/decoders" "$TARGET_DIR/rules" -type f -exec chmod 640 {} \;
$FIND "$TARGET_DIR/decoders" "$TARGET_DIR/rules" -type d -exec chmod 750 {} \;
$SYSTEMCTL restart wazuh-manager
$SYSTEMCTL status wazuh-manager -l --no-pager

