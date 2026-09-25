#!/usr/bin/env bash
# Builds the app icon (AppIcon.icns): a red yield triangle on black steel.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O "$ROOT/scripts/make-icon.swift" -o "$TMP/make-icon"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  "$TMP/make-icon" "$SET/icon_${size}x${size}.png" "$size"
  "$TMP/make-icon" "$SET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$SET" -o "$ROOT/app/Sources/onramp/AppIcon.icns"
"$TMP/make-icon" "$ROOT/design/icon-1024.png" 1024
echo "built app/Sources/onramp/AppIcon.icns"
