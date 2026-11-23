#!/bin/bash
# Compila Faro y prepara «Faro Dev.app» (copia con otro identificador) para grabar la demo.
set -euo pipefail
cd "$(dirname "$0")/../.."
./build.sh >/dev/null
pkill -f "Faro Dev.app/Contents/MacOS/Faro" 2>/dev/null || true
rm -rf "Faro Dev.app"
cp -R Faro.app "Faro Dev.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.faro.terminal.dev" -c "Set :CFBundleName Faro Dev" "Faro Dev.app/Contents/Info.plist"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
codesign --force --deep --timestamp=none --sign "${IDENTITY:--}" "Faro Dev.app" >/dev/null 2>&1
rm -f "$HOME/Library/Application Support/Faro/workspace-test.json"
