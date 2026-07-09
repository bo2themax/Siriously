#!/bin/bash
# Build & run the tool-mapping explorer (window with T0…T24 buttons).
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -import-objc-header WritingToolsPrivate.h \
  -F /System/Library/PrivateFrameworks \
  -framework AppKit -framework WritingToolsUI -framework WritingTools \
  explore.swift -o build/explore
codesign --force --sign "$(security find-identity -p codesigning 2>/dev/null | grep -q WTReviveDev && echo WTReviveDev || echo -)" build/explore 2>/dev/null || true
exec ./build/explore
