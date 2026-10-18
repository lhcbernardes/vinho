#!/usr/bin/env bash
# Gera build/Vinho.app a partir do executável SwiftPM (sem precisar de .xcodeproj).
# Uso: scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/Vinho"

APP="$ROOT/build/Vinho.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vinho"

VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Vinho</string>
  <key>CFBundleDisplayName</key><string>Vinho</string>
  <key>CFBundleIdentifier</key><string>dev.leandro.vinho</string>
  <key>CFBundleExecutable</key><string>Vinho</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Windows Executable</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.microsoft.windows-executable</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Assinatura ad-hoc (suficiente para rodar localmente).
codesign --force --deep --sign - "$APP"
echo "✓ $APP"
