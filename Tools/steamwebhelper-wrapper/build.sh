#!/usr/bin/env bash
# Recompila o wrapper e regenera Sources/WineKit/Launchers/SteamWebHelperWrapper.swift.
# Requer mingw-w64 (macOS: brew install mingw-w64; Ubuntu: apt install gcc-mingw-w64-x86-64).
set -euo pipefail
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -municode -mwindows -Os -s -o steamwebhelper.exe wrapper.c
SHA=$(shasum -a 256 steamwebhelper.exe | cut -d' ' -f1)
OUT=../../Sources/WineKit/Launchers/SteamWebHelperWrapper.swift
{
  echo "// Gerado por Tools/steamwebhelper-wrapper/build.sh — não edite à mão."
  echo "// Fonte: Tools/steamwebhelper-wrapper/wrapper.c"
  echo "import Foundation"
  echo ""
  echo "public enum SteamWebHelperWrapper {"
  echo "    public static let sha256 = \"$SHA\""
  echo "    public static let base64 = \"$(base64 < steamwebhelper.exe | tr -d '\n')\""
  echo ""
  echo "    public static var data: Data { Data(base64Encoded: base64)! }"
  echo "}"
} > "$OUT"
echo "✓ $(wc -c < steamwebhelper.exe) bytes, sha256 $SHA"
