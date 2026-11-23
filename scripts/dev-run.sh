#!/bin/bash
# Compila y abre «Faro Dev»: una copia con otro identificador para probar sin tocar
# el Faro instalado. Se abre encima, sin quitar el foco del teclado y sin guardar historial.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
pkill -f "Faro Dev.app/Contents/MacOS/Faro" 2>/dev/null || true
rm -rf "Faro Dev.app"
cp -R Faro.app "Faro Dev.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.faro.terminal.dev" -c "Set :CFBundleName Faro Dev" -c "Set :CFBundleDisplayName Faro Dev" "Faro Dev.app/Contents/Info.plist"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
codesign --force --deep --timestamp=none --sign "${IDENTITY:--}" "Faro Dev.app" >/dev/null 2>&1
open -g --env FARO_TEST_BACKGROUND=1 "Faro Dev.app"
echo "Faro Dev abierto"
