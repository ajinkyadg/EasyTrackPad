#!/bin/bash
#
# check.sh — run by the com.inputcustomizer.frameworkwatch LaunchAgent
# (see install.sh) at login and daily. Compares the live system against
# Scripts/framework-watch/baseline/ (git-tracked, updated only by
# capture-baseline.sh) and the repo's own test suite. On any drift, writes
# a diagnostic report, fires a macOS notification, and — unless a
# near-identical break was already reported recently — launches a
# headless Claude Code session in an isolated git worktree to investigate
# and draft a fix on a new branch (never main, never pushed).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

RUN_LOG="$FW_LOG_DIR/runs.log"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log() { echo "[$TIMESTAMP] $*" >> "$RUN_LOG"; }

log "check.sh starting"

if [ ! -f "$FW_BASELINE_DIR/multitouch-symbols.txt" ]; then
    log "no baseline found at $FW_BASELINE_DIR — run capture-baseline.sh once first. Exiting without alerting."
    exit 0
fi

ISSUES=()

# --- 1. Required symbols still present? ---
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
if fw_dump_multitouch_symbols "$SCRATCH/current-symbols.txt"; then
    for symbol in "${FW_REQUIRED_SYMBOLS[@]}"; do
        if ! grep -qxF "$symbol" "$SCRATCH/current-symbols.txt"; then
            ISSUES+=("MISSING SYMBOL: MultitouchSupport.framework no longer exports \`$symbol\` (used by Sources/CMultitouchSupport/shim.h).")
        fi
    done
else
    ISSUES+=("SYMBOL DUMP FAILED: couldn't dump MultitouchSupport.framework's symbol table at all (lldb/swiftc issue, or the framework's location/loading changed).")
fi

# --- 2. IORegistry shape still as expected? ---
if ! IOREG_ISSUE="$(fw_check_ioregistry_shape 2>&1)"; then
    ISSUES+=("IOREGISTRY SHAPE CHANGED: $IOREG_ISSUE")
fi

# --- 3. macOS version changed since baseline? (informational trigger — a
#         version bump alone isn't a break, but it's exactly when a break
#         is most likely, so it always forces a full report even if 1/2/4
#         are otherwise clean.) ---
BASELINE_VERSION="$(cat "$FW_BASELINE_DIR/macos-version.txt" 2>/dev/null || echo "unknown")"
CURRENT_VERSION="$(fw_macos_version)"
VERSION_CHANGED=0
if [ "$BASELINE_VERSION" != "$CURRENT_VERSION" ]; then
    VERSION_CHANGED=1
    ISSUES+=("macOS VERSION CHANGED: baseline was captured on $BASELINE_VERSION, this machine is now on $CURRENT_VERSION. Framework/IORegistry checks above still passed, but re-verify on real hardware and re-run capture-baseline.sh once confirmed working.")
fi

# --- 4. Build and test still pass? ---
BUILD_LOG="$SCRATCH/build.log"
if ! (cd "$FW_REPO_ROOT" && swift build > "$BUILD_LOG" 2>&1); then
    ISSUES+=("BUILD FAILED: \`swift build\` failed. Tail of output:
\`\`\`
$(tail -40 "$BUILD_LOG")
\`\`\`")
elif ! (cd "$FW_REPO_ROOT" && swift test >> "$BUILD_LOG" 2>&1); then
    ISSUES+=("TESTS FAILED: \`swift test\` failed. Tail of output:
\`\`\`
$(tail -60 "$BUILD_LOG")
\`\`\`")
fi

if [ ${#ISSUES[@]} -eq 0 ]; then
    log "OK — no drift detected (macOS $CURRENT_VERSION, build+test pass)."
    exit 0
fi

log "DRIFT DETECTED — ${#ISSUES[@]} issue(s). Writing report."

REPORT_FILE="$FW_LOG_DIR/report-$(date -u +"%Y%m%d-%H%M%S").md"
{
    echo "# Framework watch report — $TIMESTAMP"
    echo
    echo "Baseline: macOS $BASELINE_VERSION, captured $(cat "$FW_BASELINE_DIR/captured-at.txt" 2>/dev/null || echo unknown) at commit $(cat "$FW_BASELINE_DIR/captured-at-commit.txt" 2>/dev/null || echo unknown)"
    echo "Current: macOS $CURRENT_VERSION"
    echo
    for issue in "${ISSUES[@]}"; do
        echo "## Issue"
        echo "$issue"
        echo
    done
} > "$REPORT_FILE"

log "Report written to $REPORT_FILE"

# --- De-dupe: don't re-launch a remediation session for the exact same
#     set of issues more than once every 3 days — a break that isn't
#     fixed yet will otherwise re-trigger a brand new worktree+session on
#     every single run. ---
ISSUE_SIGNATURE_FILE="$FW_STATE_DIR/last-issue-signature.txt"
LAST_REMEDIATION_FILE="$FW_STATE_DIR/last-remediation-at.txt"
CURRENT_SIGNATURE="$(printf '%s\n' "${ISSUES[@]}" | shasum -a 256 | cut -d' ' -f1)"
SHOULD_REMEDIATE=1
if [ -f "$ISSUE_SIGNATURE_FILE" ] && [ -f "$LAST_REMEDIATION_FILE" ]; then
    LAST_SIGNATURE="$(cat "$ISSUE_SIGNATURE_FILE")"
    LAST_AT="$(cat "$LAST_REMEDIATION_FILE")"
    if [ "$LAST_SIGNATURE" = "$CURRENT_SIGNATURE" ]; then
        NOW_EPOCH="$(date -u +%s)"
        LAST_EPOCH="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_AT" +%s 2>/dev/null || echo 0)"
        AGE=$(( NOW_EPOCH - LAST_EPOCH ))
        if [ "$AGE" -lt 259200 ]; then # 3 days
            SHOULD_REMEDIATE=0
            log "Same issue signature as last remediation attempt ($LAST_AT, $((AGE / 3600))h ago) — skipping a new remediation session, notifying only."
        fi
    fi
fi

# Always notify, remediation or not — the user should know either way.
osascript -e "display notification \"${#ISSUES[@]} issue(s) found — see $REPORT_FILE\" with title \"InputCustomizer framework watch\"" >/dev/null 2>&1 || true

if [ "$SHOULD_REMEDIATE" -eq 0 ]; then
    exit 0
fi

CLAUDE_BIN="$HOME/.local/bin/claude"
if [ ! -x "$CLAUDE_BIN" ]; then
    log "claude CLI not found at $CLAUDE_BIN — skipping remediation, report+notification only."
    exit 0
fi

BRANCH="framework-watch/auto-$(date -u +"%Y%m%d-%H%M%S")"
WORKTREE_DIR="$HOME/.inputcustomizer-framework-watch/$BRANCH"
mkdir -p "$(dirname "$WORKTREE_DIR")"

log "Creating isolated worktree at $WORKTREE_DIR on branch $BRANCH"
if ! git -C "$FW_REPO_ROOT" worktree add -b "$BRANCH" "$WORKTREE_DIR" main >> "$RUN_LOG" 2>&1; then
    log "git worktree add failed — skipping remediation."
    exit 0
fi

PROMPT_FILE="$SCRATCH/prompt.md"
REPORT_CONTENT="$(cat "$REPORT_FILE")"
sed -e "s/__BRANCH__/$BRANCH/" ./remediation-prompt.template.md > "$PROMPT_FILE"
# Append the report separately (avoids sed escaping issues with the
# report's own slashes/special characters).
sed -i '' "/__REPORT__/d" "$PROMPT_FILE"
cat "$REPORT_FILE" >> "$PROMPT_FILE"

log "Launching headless Claude session in $WORKTREE_DIR (--dangerously-skip-permissions — contained by the isolated worktree, not by the permission system; see this script's header)."
CLAUDE_LOG="$FW_LOG_DIR/remediation-$(date -u +"%Y%m%d-%H%M%S").log"
(
    cd "$WORKTREE_DIR" && \
    "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
        --dangerously-skip-permissions \
        --output-format text
) > "$CLAUDE_LOG" 2>&1
CLAUDE_EXIT=$?

log "Remediation session exited $CLAUDE_EXIT — log at $CLAUDE_LOG, worktree left at $WORKTREE_DIR for review."
echo "$CURRENT_SIGNATURE" > "$ISSUE_SIGNATURE_FILE"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$LAST_REMEDIATION_FILE"

osascript -e "display notification \"Remediation attempted on branch $BRANCH — review at $WORKTREE_DIR\" with title \"InputCustomizer framework watch\"" >/dev/null 2>&1 || true
