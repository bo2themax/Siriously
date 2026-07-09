#!/bin/bash
# Remove Siriously.
set -euo pipefail

for PLIST in "$HOME/Library/LaunchAgents/bo2themax.siriously.plist" \
             "$HOME/Library/LaunchAgents/net.flexoptix.writingtoolsrevive.plist"; do
  if [ -f "$PLIST" ]; then
    echo "==> Unloading LaunchAgent $(basename "$PLIST")"
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
  fi
done

echo "==> Stopping any running instance"
pkill -x Siriously 2>/dev/null || true
pkill -x WTSpike 2>/dev/null || true   # old name

for DEST in "/Applications/Siriously.app" "/Applications/WritingToolsRevive.app"; do
  if [ -d "$DEST" ]; then
    echo "==> Removing $DEST"
    rm -rf "$DEST"
  fi
done

echo "==> Done. (You may also remove it from System Settings → Privacy & Security →"
echo "    Accessibility, and from Login Items & Extensions.)"
