#!/bin/bash
# Выпускает обновление: собирает приложение, пакует zip и dmg, публикует релиз на GitHub.
# Перед запуском: поднять номер в файле VERSION и закоммитить изменения.
#   ./release.sh            — собрать и опубликовать
#   ./release.sh --no-publish — только собрать dist/ (ничего не уходит в GitHub)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"

BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/demosufler.app/Contents/Info.plist 2>/dev/null || true)"
if [ "${REUSE_BUILD:-}" = "1" ] && [ "$BUILT" = "$VERSION" ] && [ -f dist/demosufler.zip ] && [ -f dist/demosufler.dmg ]; then
    # REUSE_BUILD=1: опубликовать уже собранный и проверенный dist/, не пересобирая.
    echo "Беру готовую сборку $VERSION из dist/"
else
    ./build.sh

    rm -rf dist
    mkdir -p dist
    # zip забирает само приложение при обновлении, dmg скачивают с лендинга.
    ditto -c -k --keepParent build/demosufler.app dist/demosufler.zip

    STAGE=$(mktemp -d)
    trap 'rm -rf "$STAGE"' EXIT
    cp -R build/demosufler.app "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "demosufler $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet dist/demosufler.dmg
fi
ls -lh dist

if [ "${1:-}" = "--no-publish" ]; then
    echo "Собрано в dist/, релиз не публиковался."
    exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Есть незакоммиченные изменения. Закоммить их и запусти снова." >&2
    exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Релиз $TAG уже есть. Подними номер в VERSION." >&2
    exit 1
fi

git push origin HEAD
gh release create "$TAG" dist/demosufler.zip dist/demosufler.dmg \
    --title "demosufler $VERSION" \
    --notes "${NOTES:-Обновление demosufler $VERSION.}"
echo "Опубликовано: $TAG"
