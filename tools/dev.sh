#!/bin/bash
# Builds build/demosufler-dev: the same code as the app, as a plain binary for this Mac only.
# It is what the tests and the product video use (see Sources/Tools.swift and Sources/Demo.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos15.0" \
    Sources/*.swift -o build/demosufler-dev
echo "Built build/demosufler-dev"
