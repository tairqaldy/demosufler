#!/bin/bash
# Ставит последнюю версию demosufler в «Программы» и запускает её.
#   curl -fsSL https://raw.githubusercontent.com/tairqaldy/demosufler/main/install.sh | bash
set -euo pipefail

URL="https://github.com/tairqaldy/demosufler/releases/latest/download/demosufler.zip"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Скачиваю demosufler…"
curl -fL --progress-bar "$URL" -o "$TMP/demosufler.zip"
ditto -x -k "$TMP/demosufler.zip" "$TMP"
codesign --verify --deep --strict "$TMP/demosufler.app"

pkill -x demosufler 2>/dev/null || true
rm -rf "$DEST/demosufler.app"
mv "$TMP/demosufler.app" "$DEST/demosufler.app"
xattr -dr com.apple.quarantine "$DEST/demosufler.app" 2>/dev/null || true

echo "Готово: $DEST/demosufler.app"
open "$DEST/demosufler.app"
