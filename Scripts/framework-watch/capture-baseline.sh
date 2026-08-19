#!/bin/bash
#
# capture-baseline.sh
#
# Records the current "known-good" shape of MultitouchSupport.framework
# (its exported symbol list) and the macOS version this app was last
# verified against — committed to the repo under Scripts/framework-watch/
# baseline/ so drift is visible in `git log`/`git diff` over time, the
# same way you'd track any other fixture.
#
# Run this manually after verifying the app actually works on a new
# macOS version (or right after `check.sh` finds real, harmless drift
# that isn't worth alerting on again) — NOT automatically. check.sh reads
# what this wrote; it never overwrites it itself.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

mkdir -p "$FW_BASELINE_DIR"

echo "Capturing MultitouchSupport.framework symbol baseline..."
if ! fw_dump_multitouch_symbols "$FW_BASELINE_DIR/multitouch-symbols.txt"; then
    echo "Failed to dump symbols — is lldb available and Terminal/this shell granted Full Disk Access if prompted?" >&2
    exit 1
fi
symbol_count=$(wc -l < "$FW_BASELINE_DIR/multitouch-symbols.txt" | tr -d ' ')
echo "  $symbol_count MT*/mt_* symbols captured."

echo "Checking required symbols are present in this capture..."
missing=0
for symbol in "${FW_REQUIRED_SYMBOLS[@]}"; do
    if ! grep -qxF "$symbol" "$FW_BASELINE_DIR/multitouch-symbols.txt"; then
        echo "  MISSING: $symbol — baseline captured from a framework that's already broken for this app!" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    echo "Refusing to save a baseline missing symbols this app actually needs. Fix the app or investigate before re-running." >&2
    exit 1
fi

fw_macos_version > "$FW_BASELINE_DIR/macos-version.txt"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$FW_BASELINE_DIR/captured-at.txt"
git -C "$FW_REPO_ROOT" rev-parse HEAD > "$FW_BASELINE_DIR/captured-at-commit.txt" 2>/dev/null || echo "unknown" > "$FW_BASELINE_DIR/captured-at-commit.txt"

echo "Checking IORegistry shape..."
if ! fw_check_ioregistry_shape; then
    echo "Refusing to save baseline — IORegistry shape check failed (see above)." >&2
    exit 1
fi

echo "Baseline captured at $(cat "$FW_BASELINE_DIR/captured-at.txt") — macOS $(cat "$FW_BASELINE_DIR/macos-version.txt")."
echo "Review and commit: git -C \"$FW_REPO_ROOT\" add Scripts/framework-watch/baseline && git -C \"$FW_REPO_ROOT\" commit -m 'Update framework-watch baseline'"
