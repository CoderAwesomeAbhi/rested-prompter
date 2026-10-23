#!/bin/bash
# Installs Rested Prompter on a Mac: downloads the latest build, puts it in Applications and opens it.
# Downloading with curl (instead of a browser) means macOS doesn't show the "unidentified developer" warning.
set -euo pipefail
URL="https://github.com/CoderAwesomeAbhi/rested-prompter/releases/latest/download/RestedPrompter-mac.zip"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Rested Prompter..."
curl -fsSL "$URL" -o "$TMP/RestedPrompter-mac.zip"
pkill -x RestedPrompter 2>/dev/null || true
rm -rf "$DEST/Rested Prompter.app"
ditto -x -k "$TMP/RestedPrompter-mac.zip" "$DEST"
xattr -dr com.apple.quarantine "$DEST/Rested Prompter.app" 2>/dev/null || true

echo "Installed: $DEST/Rested Prompter.app"
echo "Opening it now. Press 1, 2 or 3 to pick your script, then V to follow your voice."
open "$DEST/Rested Prompter.app"
