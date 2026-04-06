#!/usr/bin/env bash
# uninstall.sh — LocalTimeQuota uninstaller
# Must be run as root (sudo bash installer/uninstall.sh [--purge])
set -euo pipefail

PURGE=false
for arg in "$@"; do
  [[ "$arg" == "--purge" ]] && PURGE=true
done

if [[ $EUID -ne 0 ]]; then
  echo "uninstall.sh must be run as root (sudo bash installer/uninstall.sh)" >&2
  exit 1
fi

DAEMON_PLIST="/Library/LaunchDaemons/com.localtimequota.daemon.plist"
AGENT_PLIST="/Library/LaunchAgents/com.localtimequota.agent.plist"

# ------------------------------------------------------------
# Unload services
# ------------------------------------------------------------
echo "[uninstall] Stopping services..."
if launchctl list com.localtimequota.daemon &>/dev/null; then
  launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true
fi

# ------------------------------------------------------------
# Remove plists
# ------------------------------------------------------------
echo "[uninstall] Removing launchd plists..."
rm -f "$DAEMON_PLIST" "$AGENT_PLIST"

# ------------------------------------------------------------
# Remove binaries
# ------------------------------------------------------------
echo "[uninstall] Removing binaries..."
rm -f /Library/PrivilegedHelperTools/localtimequota-daemon
rm -f /usr/local/libexec/localtimequota-agent
rm -f /usr/local/bin/quotactl

# ------------------------------------------------------------
# Optionally remove data
# ------------------------------------------------------------
if $PURGE; then
  echo "[uninstall] --purge: removing all policy and usage data..."
  rm -rf "/Library/Application Support/LocalTimeQuota"
  rm -rf "/Library/Logs/LocalTimeQuota"
else
  echo "[uninstall] Data preserved at '/Library/Application Support/LocalTimeQuota'."
  echo "            Use --purge to remove all data."
fi

echo ""
echo "LocalTimeQuota uninstalled."
