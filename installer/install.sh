#!/usr/bin/env bash
# install.sh — LocalTimeQuota installer
# Must be run as root (sudo bash installer/install.sh [username])
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------
DAEMON_BIN="/Library/PrivilegedHelperTools/localtimequota-daemon"
AGENT_BIN="/usr/local/libexec/localtimequota-agent"
CLI_BIN="/usr/local/bin/quotactl"

DAEMON_PLIST="/Library/LaunchDaemons/com.localtimequota.daemon.plist"
AGENT_PLIST="/Library/LaunchAgents/com.localtimequota.agent.plist"

DATA_ROOT="/Library/Application Support/LocalTimeQuota"
LOG_DIR="/Library/Logs/LocalTimeQuota"

# ------------------------------------------------------------
# Check root
# ------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "install.sh must be run as root (sudo bash installer/install.sh)" >&2
  exit 1
fi

# ------------------------------------------------------------
# Build
# ------------------------------------------------------------
echo "[install] Building release binaries..."
cd "$REPO_DIR"
swift build -c release 2>&1

BUILD_DIR="$REPO_DIR/.build/release"

# ------------------------------------------------------------
# Create directories
# ------------------------------------------------------------
echo "[install] Creating directories..."
for dir in \
    "/Library/PrivilegedHelperTools" \
    "/usr/local/libexec" \
    "/usr/local/bin" \
    "$DATA_ROOT/policies" \
    "$DATA_ROOT/usage" \
    "$DATA_ROOT/state" \
    "$LOG_DIR"; do
  mkdir -p "$dir"
  chown root:wheel "$dir"
  chmod 755 "$dir"
done

# Lock down data dirs so child standard users cannot write.
chmod 700 "$DATA_ROOT/policies" "$DATA_ROOT/usage" "$DATA_ROOT/state"

# ------------------------------------------------------------
# Install binaries
# ------------------------------------------------------------
echo "[install] Installing binaries..."
install -o root -g wheel -m 755 "$BUILD_DIR/Daemon" "$DAEMON_BIN"
install -o root -g wheel -m 755 "$BUILD_DIR/Agent"  "$AGENT_BIN"
install -o root -g wheel -m 755 "$BUILD_DIR/CLI"    "$CLI_BIN"

# ------------------------------------------------------------
# Install launchd plists
# ------------------------------------------------------------
echo "[install] Installing launchd plists..."
install -o root -g wheel -m 644 \
  "$REPO_DIR/launchd/com.localtimequota.daemon.plist" "$DAEMON_PLIST"
install -o root -g wheel -m 644 \
  "$REPO_DIR/launchd/com.localtimequota.agent.plist"  "$AGENT_PLIST"

# ------------------------------------------------------------
# Bootstrap daemon
# ------------------------------------------------------------
echo "[install] Bootstrapping daemon..."
if sudo launchctl print system/com.localtimequota.daemon &>/dev/null; then
  launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true
fi
launchctl bootstrap system "$DAEMON_PLIST"
echo "[install] Daemon started."

# ------------------------------------------------------------
# Optional: create initial policy for a child user
# ------------------------------------------------------------
INITIAL_USER="${1:-}"
if [[ -n "$INITIAL_USER" ]]; then
  POLICY_FILE="$DATA_ROOT/policies/${INITIAL_USER}.json"
  if [[ ! -f "$POLICY_FILE" ]]; then
    echo "[install] Creating default policy for user: $INITIAL_USER"
    cat > "$POLICY_FILE" <<JSON
{
  "allow_parent_override": true,
  "count_idle_time": false,
  "daily_limit_seconds": 7200,
  "enabled": true,
  "enforcement_mode": "logout",
  "grace_period_seconds": 60,
  "idle_threshold_seconds": 300,
  "username": "${INITIAL_USER}",
  "version": 1,
  "warning_threshold_seconds": 300
}
JSON
    chown root:wheel "$POLICY_FILE"
    chmod 600 "$POLICY_FILE"
  else
    echo "[install] Policy already exists for $INITIAL_USER, skipping."
  fi
fi

echo ""
echo "LocalTimeQuota installed successfully."
echo ""
echo "  Daemon running:  launchctl list com.localtimequota.daemon"
echo "  Set quota:       sudo quotactl set <user> 2h"
echo "  Check status:    quotactl status <user>"
echo ""
echo "The agent will start automatically at next GUI login for any user."
