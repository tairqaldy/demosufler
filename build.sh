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

# Локальная подпись (без платного аккаунта разработчика). Подпись у каждой сборки своя,
# поэтому после обновления macOS заново спрашивает камеру, микрофон и запись экрана.
codesign --force --sign - "$APP"
echo "Готово: $APP (версия $VERSION)"
