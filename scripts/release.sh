#!/bin/bash
# Prepara una versión para publicar: Faro.app universal (Apple Silicon e Intel), un .dmg para
# arrastrar a Aplicaciones y un .zip (el que usan Homebrew y el instalador).
#   ./scripts/release.sh 1.0.0
# Deja los archivos en dist/ y escribe sus SHA-256 en dist/SHA256SUMS.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Uso: ./scripts/release.sh <versión>, por ejemplo 1.0.0}"
DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST"

FARO_UNIVERSAL=1 FARO_VERSION="$VERSION" ./build.sh
lipo -info Faro.app/Contents/MacOS/Faro

ZIP="$DIST/Faro-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent Faro.app "$ZIP"

# DMG con la app y un acceso a Aplicaciones para arrastrarla.
STAGE="$(mktemp -d)"
cp -R Faro.app "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"
hdiutil create -quiet -volname "Faro $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DIST/Faro-$VERSION.dmg"
rm -rf "${STAGE:?}"

(cd "$DIST" && shasum -a 256 Faro-"$VERSION".* > SHA256SUMS.txt && cat SHA256SUMS.txt)
