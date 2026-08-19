#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
# The SPM executable target is still named "InputCustomizer" (the built
# binary and CFBundleExecutable both match it), but the .app bundle itself
# and everything installed/signed is named "InputCustomizerLite" so this
# fork can be built, installed, and run side by side with the original
# InputCustomizer.app without one silently overwriting the other.
EXECUTABLE_NAME="InputCustomizer"
APP_NAME="InputCustomizerLite"
CONFIGURATION="release"
BUILD_PATH="${TMPDIR:-/tmp}/inputcustomizerlite-app-export"
DIST_DIR="${INPUTCUSTOMIZER_DIST_DIR:-$PROJECT_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$BUILD_PATH/$CONFIGURATION/$EXECUTABLE_NAME"
INFO_PLIST_PATH="$PROJECT_DIR/Sources/$EXECUTABLE_NAME/Resources/Info.plist"

cd "$PROJECT_DIR"
swift build -c "$CONFIGURATION" --disable-sandbox --build-path "$BUILD_PATH"

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$INFO_PLIST_PATH" "$CONTENTS_DIR/Info.plist"
chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"

LOCAL_IDENTITY_NAME="InputCustomizer Local Dev"

# A *stable* signing identity matters here — not just a valid one. macOS
# ties TCC grants (Accessibility, Input Monitoring) to the code signature;
# ad-hoc signing ("-") hashes the binary's own contents, so it produces a
# *different* identity on every rebuild and silently invalidates the
# Accessibility grant each time you iterate. Any real identity (Developer
# ID, or a free "Apple Development" cert from an Xcode account — Xcode
# often provisions one automatically) is stable across rebuilds; ad-hoc
# is the only one that isn't.
SIGN_IDENTITY="${INPUTCUSTOMIZER_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development/ { print $2; exit }')"
fi

# Last resort: create a local self-signed identity. Only reached if
# there's no Developer ID or Apple Development certificate available.
# codesign will happily sign with it by name even though it's untrusted
# (`security find-identity -v` excludes it, so we check for its
# *existence* via find-certificate instead — using -v here would look
# like "no identity" forever and re-create a duplicate on every run).
if [[ -z "$SIGN_IDENTITY" && "${INPUTCUSTOMIZER_REQUIRE_DEVELOPER_ID:-0}" != "1" ]] && command -v security >/dev/null 2>&1; then
    if ! security find-certificate -c "$LOCAL_IDENTITY_NAME" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
        printf 'No signing identity found — creating a local self-signed one ("%s") so Accessibility/Input Monitoring grants survive rebuilds...\n' "$LOCAL_IDENTITY_NAME"
        TMP_CERT_DIR="$(mktemp -d)"
        openssl req -x509 -newkey rsa:2048 -keyout "$TMP_CERT_DIR/key.pem" -out "$TMP_CERT_DIR/cert.pem" \
            -days 3650 -nodes -subj "/CN=$LOCAL_IDENTITY_NAME" \
            -addext "basicConstraints=critical,CA:FALSE" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
        openssl pkcs12 -export -out "$TMP_CERT_DIR/cert.p12" \
            -inkey "$TMP_CERT_DIR/key.pem" -in "$TMP_CERT_DIR/cert.pem" \
            -passout pass:inputcustomizer
        security import "$TMP_CERT_DIR/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
            -P inputcustomizer -T /usr/bin/codesign -A
        rm -rf "$TMP_CERT_DIR"
    fi
    SIGN_IDENTITY="$LOCAL_IDENTITY_NAME"
fi

if command -v codesign >/dev/null 2>&1; then
    if [[ "$SIGN_IDENTITY" == "$LOCAL_IDENTITY_NAME" ]]; then
        # Apple's timestamp authority only recognizes Apple-issued
        # certificates; requesting one for this self-signed identity
        # would just fail, so skip it.
        codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$APP_PATH"
        printf 'Signed with local dev identity: %s\n' "$SIGN_IDENTITY"
    elif [[ -n "$SIGN_IDENTITY" ]]; then
        codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP_PATH"
        printf 'Signed with %s\n' "$SIGN_IDENTITY"
    elif [[ "${INPUTCUSTOMIZER_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
        printf 'error: no Developer ID Application signing identity was found.\n' >&2
        printf 'Open Xcode > Settings > Accounts > Manage Certificates, then create or download a Developer ID Application certificate.\n' >&2
        exit 1
    else
        codesign --force --deep --sign - --options runtime "$APP_PATH"
        printf 'Signed ad-hoc — no stable signing identity available. Accessibility/Input Monitoring grants will need to be re-approved after every rebuild.\n'
    fi
fi

printf 'Exported %s\n' "$APP_PATH"

# Auto-install to /Applications (or INPUTCUSTOMIZER_INSTALL_DIR) so
# however you normally launch the app — Spotlight, Launchpad, double-
# clicking in Finder — picks up this build. Without this, `dist/` and
# `/Applications` silently diverge the moment anyone copies the app
# there once (as this project's own README used to suggest doing
# manually), and "I changed the code but the app looks the same" is
# very hard to diagnose from the symptom alone.
if [[ "${INPUTCUSTOMIZER_SKIP_INSTALL:-0}" != "1" ]]; then
    INSTALL_DIR="${INPUTCUSTOMIZER_INSTALL_DIR:-/Applications}"
    INSTALLED_APP_PATH="$INSTALL_DIR/$APP_NAME.app"
    pkill -f "$INSTALLED_APP_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
    rm -rf "$INSTALLED_APP_PATH"
    mkdir -p "$INSTALL_DIR"
    cp -R "$APP_PATH" "$INSTALLED_APP_PATH"
    printf 'Installed to %s — launch it from Spotlight/Applications, or `open "%s"`.\n' "$INSTALLED_APP_PATH" "$INSTALLED_APP_PATH"
    printf 'Grant Accessibility and Input Monitoring when macOS prompts (only needed once, thanks to the stable signing identity above).\n'
else
    printf 'Skipped installing to /Applications (INPUTCUSTOMIZER_SKIP_INSTALL=1) — exported build only at %s\n' "$APP_PATH"
fi
