#!/bin/bash
# Builds "Quit on Close.app" into ./build. No Xcode needed — Command Line Tools are enough.
#
# Signing: uses the "Quit on Close Self-Signed" certificate when it's in the keychain, so every build
# has the same signature and macOS keeps the Accessibility permission across updates.
# Without it the build is ad-hoc signed, and macOS treats each build as a new app.
# Override with SIGN_IDENTITY; set REQUIRE_SIGNING=1 to fail instead of falling back (used for releases).
# Set VERSION (e.g. 1.2.0) to stamp the version number, and SWIFT_FLAGS for extra build flags
# (e.g. "--arch arm64 --arch x86_64" for a universal build, which needs full Xcode).
set -euo pipefail
cd "$(dirname "$0")"

CERT_NAME="Quit on Close Self-Signed"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-identity -p codesigning | grep -q "\"$CERT_NAME\""; then
        SIGN_IDENTITY="$CERT_NAME"
    elif [[ -n "${REQUIRE_SIGNING:-}" ]]; then
        echo "error: '$CERT_NAME' not found in keychain" >&2
        exit 1
    else
        echo "warning: '$CERT_NAME' not found in keychain; ad-hoc signing" >&2
        SIGN_IDENTITY="-"
    fi
fi

# shellcheck disable=SC2086 # SWIFT_FLAGS is intentionally word-split
swift build -c release ${SWIFT_FLAGS:-}
# shellcheck disable=SC2086
BIN="$(swift build -c release ${SWIFT_FLAGS:-} --show-bin-path)/QuitOnClose"

APP="build/Quit on Close.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuitOnClose"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP (signed with: $SIGN_IDENTITY)"
