#!/bin/bash
# Собирает build/demosufler.app (универсальный: Apple silicon и Intel).
# Нужны только Command Line Tools (swiftc), Xcode не нужен.
#   VERSION=0.9.0 OUT=/tmp/old ./build.sh   — собрать другую версию в другую папку (для проверки обновлений)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
OUT="${OUT:-build}"
APP="$OUT/demosufler.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 -parse-as-library \
        -target "$ARCH-apple-macos15.0" \
        Sources/*.swift -o "$TMP/demosufler-$ARCH"
done
lipo -create "$TMP/demosufler-arm64" "$TMP/demosufler-x86_64" -output "$APP/Contents/MacOS/demosufler"

# Signing. macOS ties camera, microphone and screen recording permissions to the signature.
# With the identity made by tools/make_signing_identity.sh every build carries the same
# signature identity, so permissions given once survive updates. Without it the build gets a
# local one-off signature and macOS asks again after every update.
SIGNING="${DEMOSUFLER_SIGNING_DIR:-$HOME/Library/Application Support/demosufler-signing}"
codesign --force --sign - "$APP" 2>/dev/null
if [ -f "$SIGNING/identity.p12" ]; then
    swiftc -O tools/sign.swift -o "$TMP/sign-tool"
    "$TMP/sign-tool" "$SIGNING/identity.p12" "$SIGNING/password" "$APP" >/dev/null
    codesign --verify --deep --strict "$APP"
    echo "Signed with the demosufler identity"
else
    echo "No signing identity (run tools/make_signing_identity.sh): signed for this build only"
fi
echo "Готово: $APP (версия $VERSION)"
