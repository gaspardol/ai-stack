#!/bin/bash
# AI Stack installer for macOS:
#   curl -fsSL https://raw.githubusercontent.com/gaspardol/ai-stack/main/install.sh | bash
set -euo pipefail

REPO="gaspardol/ai-stack"
APP="/Applications/AI Stack.app"
bold() { printf "\033[1m%s\033[0m\n" "$1"; }
step() { printf "\n\033[1;36m%s\033[0m\n" "$1"; }

bold "AI Stack — writing assistant + meeting notes, powered by your own Claude plan"

major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 26 ]; then
  echo "AI Stack needs macOS 26 (Tahoe) or later — this Mac runs $(sw_vers -productVersion)."
  exit 1
fi

step "1/3  Downloading the latest release"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fL --progress-bar -o "$tmp/AI-Stack-macOS.zip" "https://github.com/$REPO/releases/latest/download/AI-Stack-macOS.zip"
ditto -x -k "$tmp/AI-Stack-macOS.zip" "$tmp/app"
pkill -x AIStack 2>/dev/null && sleep 1 || true
rm -rf "$APP"
ditto "$tmp/app/AI Stack.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "Installed $APP"

step "2/3  Claude Code (uses your own Claude subscription)"
CLAUDE="$(command -v claude || true)"
[ -z "$CLAUDE" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE="$HOME/.local/bin/claude"
if [ -z "$CLAUDE" ]; then
  echo "Claude Code is not installed — running Anthropic's official installer…"
  curl -fsSL https://claude.ai/install.sh | bash
  CLAUDE="$HOME/.local/bin/claude"
fi
if "$CLAUDE" auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
  echo "Logged in to Claude ✓"
else
  echo "Log in with your Claude account (a browser window opens)…"
  "$CLAUDE" auth login </dev/tty || echo "Run 'claude' later to log in."
fi

step "3/3  Starting AI Stack"
open "$APP"
bold "Done! AI Stack lives in your menu bar (✦). The setup window walks you through the macOS permissions."
