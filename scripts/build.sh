#!/bin/bash
# Builds AI Stack from source, installs it to /Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME="AI Stack"
WORK="${TMPDIR:-/tmp}/aistack-build" # outside ~/Documents so Finder/Spotlight leave it alone
INSTALL_DIR="/Applications"
mkdir -p "$WORK"
scripts/make_bundle.sh "$WORK/$APP_NAME.app"

echo "→ Installing to $INSTALL_DIR"
pkill -x AIStack 2>/dev/null && sleep 1 || true
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto --noextattr --noqtn "$WORK/$APP_NAME.app" "$INSTALL_DIR/$APP_NAME.app"

if [ "${NO_LAUNCH:-0}" != "1" ]; then
  echo "→ Launching"
  AGENT="gui/$(id -u)/com.gaspardoliviers.aistack.agent"
  # Prefer the launch agent (it relaunches the app after a crash); first install falls back to open.
  if launchctl print "$AGENT" >/dev/null 2>&1; then
    launchctl kickstart -k "$AGENT"
  else
    open "$INSTALL_DIR/$APP_NAME.app"
  fi
fi
echo "✓ Done"
