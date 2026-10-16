#!/bin/bash
# Builds the release downloads into dist/:
#   AI-Stack-macOS.zip    universal (Apple silicon + Intel) app
#   AI-Stack-Windows.zip  Chrome extension + helper (x64 + ARM64) + installer
set -euo pipefail
cd "$(dirname "$0")/.."
DIST="$PWD/dist"
WORK="${TMPDIR:-/tmp}/aistack-release"
rm -rf "$DIST" "$WORK"
mkdir -p "$DIST" "$WORK"

scripts/make_bundle.sh "$WORK/AI Stack.app" universal
(cd "$WORK" && ditto -c -k --norsrc --noextattr --keepParent "AI Stack.app" "$DIST/AI-Stack-macOS.zip")

windows/package.sh "$DIST"
ls -lh "$DIST"
