#!/bin/bash
# Graba y monta el vídeo de presentación de Faro (2560×1440, 60 fps, y una versión ligera en 1080p).
#   ./scripts/demo/record.sh [carpeta de salida]
# Usa datos de ejemplo en ~/FaroDemo (se crea y se borra) y «Faro Dev.app»; no toca tu Faro ni
# tus datos, no necesita permiso de grabación de pantalla y no te quita el foco del teclado.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-$PWD/docs}"
WORK="$(mktemp -d)"
./scripts/demo/prepare.sh >/dev/null
# Claude de verdad en la demo: se acepta antes el aviso de «confías en esta carpeta».
python3 scripts/demo/trust-claude.py "$HOME/FaroDemo/acme-web" >/dev/null
./scripts/demo/dev-build.sh
echo "Grabando (unos 2-3 minutos; Claude trabaja de verdad)…"
open -g --env FARO_TEST_BACKGROUND=1 --env FARO_DEMO=record --env FARO_DEMO_OUT="$WORK" "Faro Dev.app"
until [ -f "$WORK/timeline.json" ]; do sleep 2; done
sleep 1
echo "Montando…"
swiftc -O scripts/demo/Compose.swift -o "$WORK/compose"
mkdir -p "$OUT"
"$WORK/compose" "$WORK" "$OUT/faro-demo.mp4" "$PWD"
# Versión ligera para subir a GitHub.
ffmpeg -v error -y -i "$OUT/faro-demo.mp4" -vf scale=1920:1080:flags=lanczos -c:v libx264 -preset slow -crf 25 -pix_fmt yuv420p -movflags +faststart "$OUT/faro-demo-github.mp4"
ffmpeg -v error -y -ss 2.3 -i "$OUT/faro-demo.mp4" -frames:v 1 -vf scale=1920:1080:flags=lanczos "$OUT/faro-demo-poster.png"
pkill -f "Faro Dev.app/Contents/MacOS/Faro" 2>/dev/null || true
rm -rf "$HOME/.claude/projects/$(printf '%s' "$HOME/FaroDemo/acme-web" | tr '/.' '--')"
rm -rf "${HOME:?}/FaroDemo" "$HOME/Library/Application Support/Faro/projects-demo.json" "$HOME/Library/Application Support/Faro/workspace-test.json" "${WORK:?}"
ls -lh "$OUT"/faro-demo*
