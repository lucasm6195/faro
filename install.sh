#!/bin/bash
# Instala (o actualiza) Faro desde la última versión publicada en GitHub.
#   curl -fsSL https://raw.githubusercontent.com/lucasm6195/faro/main/install.sh | bash
set -euo pipefail

REPO="lucasm6195/faro"
if [ "$(uname -s)" != "Darwin" ]; then echo "Faro es solo para macOS." >&2; exit 1; fi
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" -lt 15 ]; then echo "Faro necesita macOS 15 (Sequoia) o posterior." >&2; exit 1; fi

echo "Buscando la última versión de Faro…"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
if [ -z "$URL" ]; then echo "No he encontrado la descarga. Mira https://github.com/$REPO/releases" >&2; exit 1; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Descargando $(basename "$URL")…"
curl -fL --progress-bar "$URL" -o "$TMP/Faro.zip"
ditto -x -k "$TMP/Faro.zip" "$TMP"

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
if pgrep -xq Faro; then echo "Cierra Faro antes de actualizarlo y vuelve a ejecutar esto." >&2; exit 1; fi
rm -rf "$DEST/Faro.app"
mv "$TMP/Faro.app" "$DEST/"
# Faro no está notarizado por Apple: sin esto, macOS no dejaría abrirlo la primera vez.
xattr -dr com.apple.quarantine "$DEST/Faro.app" 2>/dev/null || true

echo "Faro instalado en $DEST/Faro.app"
open "$DEST/Faro.app"
