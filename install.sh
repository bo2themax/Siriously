#!/bin/bash
# Install Siriously: build, copy to /Applications, register its Services, and
# (optionally) install a LaunchAgent that keeps one warm instance running so
# invocations are instant.
#
#   ./install.sh            # install to /Applications + register Services
#   ./install.sh --resident # also install a login LaunchAgent (always-warm)
set -euo pipefail
cd "$(dirname "$0")"

RESIDENT=0
[ "${1:-}" = "--resident" ] && RESIDENT=1

echo "==> Building…"
./build-app.sh >/dev/null

# Clean up the old (pre-rename) bundle if present.
rm -rf "/Applications/WritingToolsRevive.app"

DEST="/Applications/Siriously.app"
echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R build/Siriously.app "$DEST"

echo "==> Registering with Launch Services"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$DEST"

# Launch once so it registers its Services provider and prompts for Accessibility.
echo "==> Launching once (grant Accessibility when prompted)"
open "$DEST"

if [ "$RESIDENT" = "1" ]; then
  PLIST="$HOME/Library/LaunchAgents/bo2themax.siriously.plist"
  echo "==> Installing LaunchAgent $PLIST"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>bo2themax.siriously</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/Siriously</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "    LaunchAgent loaded (keeps the Writing Tools service warm)."
fi

cat <<EOF

==> Installed.

Next:
  1. Grant Accessibility: System Settings → Privacy & Security → Accessibility →
     enable "Siriously" (needed to read the selection and write the result back).
  2. If the Services items don't appear, enable them in:
     System Settings → Keyboard → Keyboard Shortcuts → Services → Text.

Use: select text in any app → right-click → Services → "Proofread" / "Rewrite" / "Siriously"
     (or the app menu → Services).

Uninstall: ./uninstall.sh
EOF
