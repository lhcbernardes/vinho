#!/usr/bin/env bash
# Gera build/Vinho.app a partir do executável SwiftPM (sem precisar de .xcodeproj).
#
# Uso: scripts/bundle.sh [--debug] [--install]
#   --debug    build de debug (padrão: release)
#   --install  copia para ~/Applications/Vinho.app e cria atalho na Mesa (Desktop)
set -euo pipefail

CONFIG="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --install) INSTALL=1 ;;
    *) echo "opção desconhecida: $arg" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCHS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)/Vinho"

APP="$ROOT/build/Vinho.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vinho"

# Ícone: Resources/AppIcon.png (1024x1024) → AppIcon.icns
ICON_SRC="$ROOT/Resources/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

# cabextract embutido (o winetricks precisa dele). Usa o do Homebrew se ele
# só depender de bibliotecas do sistema; senão o Vinho procura em runtime.
CAB="$(command -v cabextract || true)"
if [[ -n "$CAB" ]]; then
  CAB="$(readlink -f "$CAB" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CAB")"
  if ! otool -L "$CAB" | tail -n +2 | grep -qv -e '/usr/lib/' -e '/System/'; then
    mkdir -p "$APP/Contents/Resources/bin"
    cp "$CAB" "$APP/Contents/Resources/bin/cabextract"
    chmod 755 "$APP/Contents/Resources/bin/cabextract"
    echo "✓ cabextract embutido ($(cabextract --version 2>/dev/null | head -1))"
  else
    echo "⚠️  cabextract do Homebrew depende de bibliotecas externas; não embutido"
  fi
else
  echo "ℹ️  cabextract não encontrado (brew install cabextract para embuti-lo)"
fi

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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Programa do Windows</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>exe</string><string>msi</string><string>lnk</string><string>bat</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Vinho Bottle</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>CFBundleTypeExtensions</key><array><string>vinhobottle</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Assinatura ad-hoc (suficiente para rodar localmente).
codesign --force --deep --sign - "$APP"
echo "✓ $APP"

if [[ "$INSTALL" == 1 ]]; then
  DEST="$HOME/Applications/Vinho.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # Faz o Launchpad/Spotlight/Finder enxergarem o app e o ícone novo.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  touch "$DEST"
  echo "✓ instalado em $DEST"

  # Atalho na Mesa: alias do Finder (mostra o ícone); se o Finder negar, symlink.
  rm -f "$HOME/Desktop/Vinho" "$HOME/Desktop/Vinho.app"
  if osascript -e "tell application \"Finder\" to make alias file to (POSIX file \"$DEST\") at desktop with properties {name:\"Vinho\"}" >/dev/null 2>&1; then
    echo "✓ atalho criado na Mesa (alias)"
  else
    ln -sf "$DEST" "$HOME/Desktop/Vinho"
    echo "✓ atalho criado na Mesa (link simbólico)"
  fi
fi
