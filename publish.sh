#!/bin/bash
# First publication: creates the public GitHub repository tairqaldy/demosufler (if it is not
# there yet), pushes the code and publishes the release with the already built dist/ files.
# Later versions only need ./release.sh.
set -euo pipefail
cd "$(dirname "$0")"

REPO="tairqaldy/demosufler"

if gh repo view "$REPO" >/dev/null 2>&1; then
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
    git push -u origin main
else
    gh repo create "$REPO" --public --source . --remote origin --push \
        --description "Teleprompter for macOS: your script under the camera, camera and screen recording, launch-ready video"
fi

NOTES="${NOTES:-Launch video mode, English and Russian interface, fixes for the freeze and for headphone sound quality.}" \
    REUSE_BUILD=1 ./release.sh

echo
echo "Repository: https://github.com/$REPO"
echo "Download:   https://github.com/$REPO/releases/latest/download/demosufler.dmg"
