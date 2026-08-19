#!/bin/bash
#
# lib.sh — shared helpers for capture-baseline.sh and check.sh.
#
# Not meant to be run directly. Both scripts `source` this.

# Repo root, resolved from this file's own location so it works regardless
# of the caller's cwd (matters for launchd, which doesn't set one).
FW_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FW_BASELINE_DIR="$FW_REPO_ROOT/Scripts/framework-watch/baseline"
FW_STATE_DIR="$HOME/Library/Application Support/InputCustomizer/framework-watch"
FW_LOG_DIR="$HOME/Library/Logs/InputCustomizer/framework-watch"

mkdir -p "$FW_STATE_DIR" "$FW_LOG_DIR"

# Every exported C symbol from MultitouchSupport.framework whose absence
# would break this app specifically (not the framework's full ~1000-symbol
# surface, which churns across macOS versions with plenty of irrelevant
# noise) — see Sources/CMultitouchSupport/shim.h for where each is used.
FW_REQUIRED_SYMBOLS=(
    MTDeviceCreateDefault
    MTDeviceCreateFromService
    MTDeviceRelease
    MTRegisterContactFrameCallback
    MTUnregisterContactFrameCallback
    MTDeviceStart
    MTDeviceStop
)

# Dumps MultitouchSupport.framework's exported symbol table by compiling a
# tiny helper that dlopen()s it, launching that helper under lldb, and
# reading its symtab back out — the same technique used to discover
# MTDeviceCreateFromService in the first place (see git history / this
# file's own baseline). Needed because the framework is fully
# shared-cache-resident on modern macOS (no standalone file on disk for
# `nm`/`otool` to read directly).
#
# Writes the sorted list of MT*/mt_* symbol names to $1.
fw_dump_multitouch_symbols() {
    local out_file="$1"
    local scratch
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' RETURN

    cat > "$scratch/load-mts.swift" <<'EOF'
import Foundation
let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
guard handle != nil else { exit(1) }
Thread.sleep(forTimeInterval: 30)
EOF

    if ! swiftc "$scratch/load-mts.swift" -o "$scratch/load-mts" 2>"$scratch/swiftc.err"; then
        echo "fw_dump_multitouch_symbols: swiftc failed:" >&2
        cat "$scratch/swiftc.err" >&2
        return 1
    fi

    lldb --batch \
        -o "target create $scratch/load-mts" \
        -o "run" \
        -o "target modules dump symtab MultitouchSupport" \
        -o "quit" \
        > "$scratch/lldb.out" 2>&1

    grep -oE '[A-Za-z_][A-Za-z0-9_]*$' "$scratch/lldb.out" \
        | grep -E '^(MT|mt_)' \
        | sort -u > "$out_file"

    [ -s "$out_file" ]
}

# Checks that at least one AppleMultitouchDevice IORegistry entry exists
# with the property keys this app's device-selection logic
# (MultitouchGestureEngine.findService) actually depends on — NOT a raw
# diffable dump, deliberately: instance *count* varies with whether a
# Magic Mouse happens to be connected right now (expected, not a break),
# so this only checks shape, never equality against a snapshot. Prints
# any missing property to stdout and returns non-zero if anything's
# missing or no instance exists at all.
fw_check_ioregistry_shape() {
    # The dump is a few MB (huge hex-blob accel-table properties). Piping
    # it into `grep -q` (which exits the instant it finds a match) is a
    # classic `pipefail` trap: grep closing its end of the pipe early
    # SIGPIPEs the still-writing producer, and pipefail then reports that
    # broken pipe as the *pipeline's* exit status — even though grep
    # itself found the match — making every check here spuriously report
    # "missing". Here-strings sidestep it: no `|` pipeline, so there's
    # nothing for pipefail to reinterpret; grep's own exit status is what
    # `if !` actually sees.
    local dump
    dump="$(ioreg -c AppleMultitouchDevice -l -w0 2>/dev/null)"
    local instance_count
    instance_count="$(grep -c '<class AppleMultitouchDevice,' <<< "$dump")"
    if [ "$instance_count" -lt 1 ]; then
        echo "no AppleMultitouchDevice instance found at all (expected at least the built-in trackpad)"
        return 1
    fi
    local ok=0
    for key in "MT Built-In" "MTHIDDevice" "Product" "Transport" "DeviceUsagePairs"; do
        if ! grep -qF "\"$key\" =" <<< "$dump"; then
            echo "missing IORegistry property on every AppleMultitouchDevice instance: $key"
            ok=1
        fi
    done
    return $ok
}

fw_macos_version() {
    sw_vers -productVersion
}
