#!/usr/bin/env bash
# Purpose: Deploy Docker image monitoring scripts and Zabbix Agent2 config.
# Output: ONLY colored log lines -> SUCCESS/ERROR | DATE | MESSAGE

set -o pipefail

# -------------------- Fixed configuration --------------------
REPO_URL="https://github.com/pthoelken/docker-zabbix-image-monitoring.git"
REPO_BRANCH="main"

DEST_ZBX_DIR="/etc/zabbix/zabbix_agent2.d"
DEST_SCRIPTS_DIR="/etc/zabbix/scripts"

SRC_CONF_REL="docker_updates.conf"
SRC_SCRIPT_REL="docker_image_check.sh"

DEST_CONF_FILE="$DEST_ZBX_DIR/docker_updates.conf"
DEST_SCRIPT_FILE="$DEST_SCRIPTS_DIR/docker_image_check.sh"

# -------------------- Logging --------------------
ts()    { date '+%Y-%m-%d %H:%M:%S'; }
ok()    { echo -e "\e[32mSUCCESS\e[0m | $(ts) | $*"; }
err()   { echo -e "\e[31mERROR\e[0m   | $(ts) | $*" >&2; }
abort() { err "$*"; exit 1; }

# -------------------- Pre-checks --------------------
[ "$EUID" -eq 0 ] || abort "Please run as root."
[ -n "$REPO_URL" ] || abort "REPO_URL is empty; set it inside the script."

command -v docker >/dev/null 2>&1 || abort "Docker is not installed or not in PATH. Install Docker first."
ok "Docker is present."

[ -d "$DEST_ZBX_DIR" ] || abort "Missing destination path: $DEST_ZBX_DIR – is Zabbix Agent2 installed?"
ok "Destination paths exist."

# -------------------- Ensure git is present --------------------
if ! command -v git >/dev/null 2>&1; then
  ok "git not found – installing silently."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || abort "apt-get update failed."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git || abort "Installing git failed."
  ok "git installed."
else
  ok "git is present."
fi

# -------------------- Ensure skopeo is present --------------------
if ! command -v skopeo >/dev/null 2>&1; then
  ok "skopeo not found – installing silently."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || abort "apt-get update failed."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo || abort "Installing skopeo failed."
  ok "skopeo installed."
else
  ok "skopeo is present."
fi

# -------------------- Ensure jq is present --------------------
if ! command -v jq >/dev/null 2>&1; then
  ok "jq not found – installing silently."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || abort "apt-get update failed."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq || abort "Installing jq failed."
  ok "jq installed."
else
  ok "jq is present."
fi

# -------------------- Clone to /tmp --------------------
TMP_DIR="$(mktemp -d -t repo-XXXXXX)" || abort "mktemp failed."
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_DIR="$TMP_DIR/repo"
if git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR" >/dev/null 2>&1; then
  ok "Repository cloned: $REPO_URL (branch: $REPO_BRANCH)"
else
  abort "Cloning repository failed: $REPO_URL (branch: $REPO_BRANCH)"
fi

# -------------------- Validate sources --------------------
SRC_CONF="$REPO_DIR/$SRC_CONF_REL"
SRC_SCRIPT="$REPO_DIR/$SRC_SCRIPT_REL"

[ -f "$SRC_CONF" ]   || abort "Source file missing in repo: $SRC_CONF_REL"
[ -f "$SRC_SCRIPT" ] || abort "Source file missing in repo: $SRC_SCRIPT_REL"
ok "Source files found."

# -------------------- Create scripts directory if missing --------------------
if [ ! -d "$DEST_SCRIPTS_DIR" ]; then
  mkdir -p "$DEST_SCRIPTS_DIR" || abort "Could not create directory: $DEST_SCRIPTS_DIR"
  ok "Created directory: $DEST_SCRIPTS_DIR"
else
  ok "Scripts directory exists: $DEST_SCRIPTS_DIR"
fi

# -------------------- Copy monitoring script --------------------
if install -m 0755 -o root -g zabbix "$SRC_SCRIPT" "$DEST_SCRIPT_FILE"; then
  ok "Copied: $SRC_SCRIPT_REL → $DEST_SCRIPT_FILE"
else
  abort "Copy failed: $SRC_SCRIPT_REL → $DEST_SCRIPT_FILE"
fi

# -------------------- Copy Zabbix Agent2 config --------------------
if install -m 0644 "$SRC_CONF" "$DEST_CONF_FILE"; then
  ok "Copied: $SRC_CONF_REL → $DEST_CONF_FILE"
else
  abort "Copy failed: $SRC_CONF_REL → $DEST_CONF_FILE"
fi

# -------------------- Grant zabbix user Docker access --------------------
if id zabbix >/dev/null 2>&1; then
  if usermod -aG docker zabbix; then
    ok "User 'zabbix' added to 'docker' group. Note: re-login or restart required for group membership to take effect."
  else
    abort "Failed to add 'zabbix' user to 'docker' group."
  fi
else
  abort "User 'zabbix' does not exist. Is Zabbix Agent installed?"
fi

# -------------------- Restart Zabbix Agent2 --------------------
if systemctl restart zabbix-agent2.service >/dev/null 2>&1; then
  sleep 1
  if systemctl is-active --quiet zabbix-agent2.service; then
    ok "Zabbix Agent2 restarted successfully."
  else
    abort "Zabbix Agent2 is not active after restart."
  fi
else
  abort "Restarting zabbix-agent2.service failed."
fi

ok "Deployment finished."
ok "Next step: Import 'docker_image_updates_template.yaml' into your Zabbix server and assign it to this host."
