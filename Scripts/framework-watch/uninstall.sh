#!/bin/bash
#
# uninstall.sh — removes the com.inputcustomizer.frameworkwatch LaunchAgent.
# Does not delete logs/reports/baseline or any remediation worktrees left
# under ~/.inputcustomizer-framework-watch/ — remove those manually if
# you don't want them kept.
set -euo pipefail

PLIST_DEST="$HOME/Library/LaunchAgents/com.inputcustomizer.frameworkwatch.plist"

launchctl bootout "gui/$(id -u)/com.inputcustomizer.frameworkwatch" 2>/dev/null || true
rm -f "$PLIST_DEST"

echo "Uninstalled. (Logs, reports, and any remediation worktrees under ~/.inputcustomizer-framework-watch/ were left in place.)"
