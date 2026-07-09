#!/bin/bash
# Build the Siriously Services agent into a signed .app and register it with
# Launch Services so the Services items appear system-wide.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Siriously.app"
BIN="$APP/Contents/MacOS/Siriously"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Siriously</string>
  <key>CFBundleIdentifier</key><string>bo2themax.siriously</string>
  <key>CFBundleExecutable</key><string>Siriously</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleIconFile</key><string>Siriously</string>
  <key>CFBundleIconName</key><string>Siriously</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Proofread</string></dict>
      <key>NSMessage</key><string>proofread</string>
      <key>NSPortName</key><string>Siriously</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.plain-text</string><string>public.rtf</string><string>public.text</string><string>NSStringPboardType</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Rewrite</string></dict>
      <key>NSMessage</key><string>rewrite</string>
      <key>NSPortName</key><string>Siriously</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.plain-text</string><string>public.rtf</string><string>public.text</string><string>NSStringPboardType</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Friendly</string></dict>
      <key>NSMessage</key><string>friendly</string>
      <key>NSPortName</key><string>Siriously</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.plain-text</string><string>public.rtf</string><string>public.text</string><string>NSStringPboardType</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Professional</string></dict>
      <key>NSMessage</key><string>professional</string>
      <key>NSPortName</key><string>Siriously</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.plain-text</string><string>public.rtf</string><string>public.text</string><string>NSStringPboardType</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Concise</string></dict>
      <key>NSMessage</key><string>concise</string>
      <key>NSPortName</key><string>Siriously</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.plain-text</string><string>public.rtf</string><string>public.text</string><string>NSStringPboardType</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Summary</string></dict>
      <key>NSMessage</key><string>summary</string>
      <key>NSPortName</key><string>Siriously</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.plain-text</string><string>public.rtf</string><string>public.text</string><string>NSStringPboardType</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>List</string></dict>
      <key>NSMessage</key><string>list</string>
      <key>NSPortName</key><string>Siriously</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.plain-text</string><string>public.rtf</string><string>public.text</string><string>NSStringPboardType</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Table</string></dict>
      <key>NSMessage</key><string>table</string>
      <key>NSPortName</key><string>Siriously</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.plain-text</string><string>public.rtf</string><string>public.text</string><string>NSStringPboardType</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Siriously</string></dict>
      <key>NSMessage</key><string>writingTools</string>
      <key>NSPortName</key><string>Siriously</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.plain-text</string><string>public.rtf</string><string>public.text</string><string>NSStringPboardType</string></array>
    </dict>
  </array>
</dict></plist>
PLIST

swiftc -O \
  -import-objc-header WritingToolsPrivate.h \
  -F /System/Library/PrivateFrameworks \
  -framework AppKit -framework WritingToolsUI -framework WritingTools \
  Sources/main.swift -o "$BIN"

# Compile the Icon Composer icon (Liquid Glass) into the bundle: produces
# Assets.car (modern, CFBundleIconName) + Siriously.icns (fallback, CFBundleIconFile).
if [ -d "$PWD/Siriously.icon" ]; then
  xcrun actool "$PWD/Siriously.icon" \
    --compile "$PWD/$APP/Contents/Resources" \
    --app-icon Siriously \
    --platform macosx --minimum-deployment-target 27.0 \
    --output-partial-info-plist /tmp/wt-icon-partial.plist \
    --output-format human-readable-text 2>&1 | grep -i error || true
  [ -f "$PWD/$APP/Contents/Resources/Siriously.icns" ] && echo "icon compiled" || echo "icon compile FAILED"
fi

# Signing. Priority:
#   1. WT_SIGN_IDENTITY env  — an explicit identity (e.g. "Developer ID Application: …")
#      for CI / distribution; adds the hardened runtime so the app can be notarized.
#   2. WTReviveDev           — the stable local self-signed identity (AX/TCC grant
#                              persists across rebuilds during development).
#   3. ad-hoc                — anything else.
if [ -n "${WT_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --options runtime \
    --sign "$WT_SIGN_IDENTITY" --identifier bo2themax.siriously "$APP"
  echo "signed with '$WT_SIGN_IDENTITY' (hardened runtime, for distribution)"
elif security find-identity -p codesigning 2>/dev/null | grep -q "WTReviveDev"; then
  codesign --force --sign WTReviveDev --identifier bo2themax.siriously "$APP"
  echo "signed with WTReviveDev (stable local identity)"
else
  codesign --force --sign - "$APP"
  echo "signed ad-hoc (no identity; Accessibility grant won't persist across rebuilds)"
fi

# Register with Launch Services so the Services menu picks up the items.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$PWD/$APP"
echo "Built + registered $APP"
echo "Launch it (agent), then the items appear under the Services menu / right-click → Services."
