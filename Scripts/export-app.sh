#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="InputCustomizer"
CONFIGURATION="release"
BUILD_PATH="${TMPDIR:-/tmp}/inputcustomizer-app-export"
DIST_DIR="${INPUTCUSTOMIZER_DIST_DIR:-$PROJECT_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$BUILD_PATH/$CONFIGURATION/$APP_NAME"
INFO_PLIST_PATH="$PROJECT_DIR/Sources/$APP_NAME/Resources/Info.plist"

cd "$PROJECT_DIR"
swift build -c "$CONFIGURATION" --disable-sandbox --build-path "$BUILD_PATH"

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
cp "$INFO_PLIST_PATH" "$CONTENTS_DIR/Info.plist"
chmod 755 "$MACOS_DIR/$APP_NAME"

SIGN_IDENTITY="${INPUTCUSTOMIZER_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
fi

if command -v codesign >/dev/null 2>&1; then
    if [[ -n "$SIGN_IDENTITY" ]]; then
        codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP_PATH"
        printf 'Signed with %s\n' "$SIGN_IDENTITY"
    elif [[ "${INPUTCUSTOMIZER_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
        printf 'error: no Developer ID Application signing identity was found.\n' >&2
        printf 'Open Xcode > Settings > Accounts > Manage Certificates, then create or download a Developer ID Application certificate.\n' >&2
        exit 1
    else
        codesign --force --deep --sign - --options runtime "$APP_PATH"
        printf 'Signed ad-hoc because no Developer ID Application identity was found.\n'
    fi
fi

printf 'Exported %s\n' "$APP_PATH"
printf 'Move it to /Applications, launch it, then grant Accessibility and Input Monitoring permissions when macOS prompts.\n'
