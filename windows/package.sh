#!/bin/bash
# Builds "AI Stack for Windows.zip": helper (x64 + arm64), Chrome extension and installer.
set -euo pipefail
cd "$(dirname "$0")"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 PATH="$HOME/.dotnet:$PATH"
OUT="${TMPDIR:-/tmp}/aistack-windows"
PKG="$OUT/AI Stack for Windows"
rm -rf "$OUT" && mkdir -p "$PKG"

for arch in x64 arm64; do
  echo "→ Publishing helper ($arch)"
  dotnet publish helper/AIStackHelper.csproj -c Release -r "win-$arch" --self-contained -p:DebugType=none -o "$PKG/helper-$arch" >/dev/null
  # Whisper ships native libraries for every OS; keep only this architecture's.
  find "$PKG/helper-$arch/runtimes" -mindepth 1 -maxdepth 1 -type d ! -name "win-$arch" -exec rm -rf {} +
  rm -f "$PKG/helper-$arch/ggml-metal.metal"
done
echo "→ Copying extension"
cp -R extension "$PKG/extension"

cat > "$PKG/Install AI Stack.cmd" <<'CMD'
@echo off
setlocal
set ARCH=x64
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set ARCH=arm64
if /I "%PROCESSOR_ARCHITEW6432%"=="ARM64" set ARCH=arm64
"%~dp0helper-%ARCH%\AIStackHelper.exe" --install
CMD
cat > "$PKG/Uninstall AI Stack.cmd" <<'CMD'
@echo off
"%LOCALAPPDATA%\AIStack\helper\AIStackHelper.exe" --uninstall
pause
CMD
cat > "$PKG/README.txt" <<'TXT'
AI Stack for Windows
====================
Writing assistant (red/blue underlines, Ctrl+Alt+A to accept all) and automatic
meeting notes for calls in Chrome, using your Claude subscription.

Install (about 5 minutes, once):
 1. Right-click the downloaded zip > Properties > tick "Unblock" > OK, then extract it.
 2. Double-click "Install AI Stack.cmd".
    If Windows shows "Windows protected your PC": click "More info" > "Run anyway".
 3. Follow the window: it installs Claude Code if needed, asks you to log in,
    downloads the speech model and opens chrome://extensions.
 4. In Chrome: turn on "Developer mode" (top right) > "Load unpacked" >
    pick the folder the installer copied to your clipboard
    (%LOCALAPPDATA%\AIStack\extension). Pin the AI Stack icon.

Update: run "Install AI Stack.cmd" from the new zip, then in chrome://extensions click
the reload arrow on the AI Stack card (or restart Chrome).

Use:
 - Type in Gmail or any web text box: errors get a red underline, awkward phrasing blue.
   Hover to see the fix, click it, or press Ctrl+Alt+A to accept everything.
 - Join a call in Google Meet / Teams / Zoom in Chrome: notes start automatically
   (red "REC" on the AI Stack icon). Open the notepad from the pill at the bottom-left
   of the call page to type your own notes. Notes are ready a minute after the call.
 - All meetings: AI Stack icon > "All meetings". Markdown copies are saved in
   Documents\Meeting Notes.
TXT

echo "→ Zipping"
(cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "AI Stack for Windows" "AI-Stack-Windows.zip")
DEST="${1:-$HOME/Desktop}"
mkdir -p "$DEST"
cp "$OUT/AI-Stack-Windows.zip" "$DEST/"
du -sh "$DEST/AI-Stack-Windows.zip"
echo "✓ $DEST/AI-Stack-Windows.zip"
