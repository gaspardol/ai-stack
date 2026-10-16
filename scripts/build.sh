#!/bin/bash
# Builds AI Stack, signs it, installs it to /Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AI Stack"
BUILD_DIR="${TMPDIR:-/tmp}/aistack-build" # outside ~/Documents so Finder/Spotlight leave it alone
BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications"

if [ ! -f Support/AppIcon.icns ]; then
  echo "→ Rendering icon"
  TMP=$(mktemp -d)
  swift scripts/make_icon.swift "$TMP/icon.png"
  mkdir -p "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Support/AppIcon.icns
  rm -rf "$TMP"
fi

echo "→ Compiling (release)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/AIStack"

echo "→ Bundling"
rm -rf "$BUNDLE"
mkdir -p "$BUILD_DIR"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/AIStack"
cp Support/Info.plist "$BUNDLE/Contents/Info.plist"
cp Support/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
mkdir -p "$BUNDLE/Contents/Library/LaunchAgents"
cp Support/com.gaspardoliviers.aistack.agent.plist "$BUNDLE/Contents/Library/LaunchAgents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$BUNDLE/Contents/Info.plist"

# A stable signing identity keeps macOS privacy permissions (Accessibility, Microphone…) across rebuilds.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -E 'Apple Development|Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)}"
if [ -z "$IDENTITY" ]; then
  echo "→ No signing identity found; ad-hoc signing (permissions may need re-granting after each build)"
  IDENTITY="-"
else
  echo "→ Signing with: $IDENTITY"
fi
for attempt in 1 2 3; do
  xattr -cr "$BUNDLE"
  if codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE" 2>/dev/null; then break; fi
  [ "$attempt" = 3 ] && { echo "✗ codesign failed"; codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE"; exit 1; }
  sleep 1
done

echo "→ Installing to $INSTALL_DIR"
pkill -x AIStack 2>/dev/null && sleep 1 || true
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto --noextattr --noqtn "$BUNDLE" "$INSTALL_DIR/$APP_NAME.app"

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
