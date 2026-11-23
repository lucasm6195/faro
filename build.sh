#!/bin/bash
# Compila Faro y crea Faro.app en esta carpeta.
set -euo pipefail
cd "$(dirname "$0")"

# FARO_UNIVERSAL=1 compila para Apple Silicon e Intel a la vez (para publicar).
ARCH_FLAGS=()
if [ "${FARO_UNIVERSAL:-0}" = 1 ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c release --product Faro ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/Faro"
VERSION="${FARO_VERSION:-1.0.0}"

APP="Faro.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Faro"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Fonts Resources/Logos "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Faro</string>
  <key>CFBundleDisplayName</key><string>Faro</string>
  <key>CFBundleExecutable</key><string>Faro</string>
  <key>CFBundleIdentifier</key><string>dev.faro.terminal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Faro · Terminal nativa para macOS</string>
  <key>NSDesktopFolderUsageDescription</key><string>Para que los programas que ejecutas en Faro puedan trabajar con archivos del Escritorio.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Para que los programas que ejecutas en Faro puedan trabajar con archivos de Documentos.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Para que los programas que ejecutas en Faro puedan trabajar con archivos de Descargas.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Para que los programas que ejecutas en Faro puedan usar discos externos.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Para que los programas que ejecutas en Faro puedan usar unidades de red.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Carpeta</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Script de terminal</string>
      <key>CFBundleTypeRole</key><string>Shell</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.apple.terminal.shell-script</string><string>public.unix-executable</string></array>
    </dict>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Terminal</string>
      <key>CFBundleURLSchemes</key><array><string>ssh</string><string>telnet</string><string>x-man-page</string></array>
    </dict>
  </array>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Nueva pestaña de Faro aquí</string></dict>
      <key>NSMessage</key><string>openFolderService</string>
      <key>NSPortName</key><string>Faro</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.folder</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Abrir Claude Code aquí con Faro</string></dict>
      <key>NSMessage</key><string>openClaudeService</string>
      <key>NSPortName</key><string>Faro</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Firma con tu certificado de desarrollador si lo hay: así macOS reconoce a Faro entre versiones
# y recuerda los permisos (carpetas, notificaciones). Sin certificado, firma ad hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
fi
echo "Listo: $(pwd)/$APP"
