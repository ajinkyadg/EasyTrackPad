#!/bin/bash
#
# install.sh — installs the com.inputcustomizer.frameworkwatch LaunchAgent
# so check.sh runs automatically at every login and daily at 10:15am,
# indefinitely, independent of any Claude Code / terminal session being
# open. Safe to re-run (reinstalls cleanly).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

PLIST_DEST="$HOME/Library/LaunchAgents/com.inputcustomizer.frameworkwatch.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$FW_LOG_DIR"

sed -e "s#__CHECK_SCRIPT__#$FW_REPO_ROOT/Scripts/framework-watch/check.sh#" \
    -e "s#__LOG_DIR__#$FW_LOG_DIR#" \
    ./com.inputcustomizer.frameworkwatch.plist > "$PLIST_DEST"

launchctl bootout "gui/$(id -u)/com.inputcustomizer.frameworkwatch" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo "Installed and loaded: $PLIST_DEST"
echo "Runs check.sh at every login, plus daily at 10:15am local time."
echo "Logs: $FW_LOG_DIR/runs.log (every run), $FW_LOG_DIR/report-*.md (only when drift is found)"
echo "Uninstall: Scripts/framework-watch/uninstall.sh"
