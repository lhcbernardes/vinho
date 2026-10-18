#!/usr/bin/env bash
# Instala um build do Wine (Gcenx/macOS_Wine_builds) como runtime gerenciado do Vinho.
# Uso: scripts/install-runtime.sh [stable|devel|staging] [versão]
#   ex.: scripts/install-runtime.sh devel 11.16
set -euo pipefail

FLAVOR="${1:-devel}"
case "$FLAVOR" in
  stable)        VERSION="${2:-11.0_1}" ;;
  devel|staging) VERSION="${2:-11.16}" ;;
  *) echo "sabor inválido: $FLAVOR (use stable, devel ou staging)" >&2; exit 1 ;;
esac

URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/${VERSION}/wine-${FLAVOR}-${VERSION}-osx64.tar.xz"
DEST="$HOME/Library/Application Support/Vinho/Runtimes/wine-${FLAVOR}-${VERSION}"

if [[ -e "$DEST" ]]; then
  echo "Já instalado: $DEST"; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "↓ $URL"
curl -fL --progress-bar "$URL" -o "$TMP/wine.tar.xz"
tar -xJf "$TMP/wine.tar.xz" -C "$TMP"

APP="$(find "$TMP" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$APP" && -d "$APP/Contents/Resources/wine/bin" ]] || { echo "layout inesperado no tarball" >&2; exit 1; }

mkdir -p "$DEST"
cp -R "$APP/Contents/Resources/wine/." "$DEST/"
echo "${FLAVOR} ${VERSION}" > "$DEST/VERSION"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "✓ Runtime instalado em: $DEST"
"$DEST/bin/wine" --version 2>/dev/null || true
