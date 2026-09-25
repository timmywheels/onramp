#!/usr/bin/env bash
# Builds the app icon (AppIcon.icns) from design/icon.svg.
#   ./scripts/make-icon.sh          # black steel, silver mark (default, Linear-like)
#   ./scripts/make-icon.sh rose     # rose background, white mark
#   ./scripts/make-icon.sh dark     # graphite background, rose mark
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARIANT="${1:-steel}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O "$ROOT/scripts/make-icon.swift" -o "$TMP/make-icon" 2>/dev/null
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  "$TMP/make-icon" "$ROOT/design/icon.svg" "$SET/icon_${size}x${size}.png" "$size" "$VARIANT"
  "$TMP/make-icon" "$ROOT/design/icon.svg" "$SET/icon_${size}x${size}@2x.png" "$((size * 2))" "$VARIANT"
done
iconutil -c icns "$SET" -o "$ROOT/app/Sources/pairprogram/AppIcon.icns"
"$TMP/make-icon" "$ROOT/design/icon.svg" "$ROOT/design/icon-$VARIANT-1024.png" 1024 "$VARIANT"
echo "built app/Sources/pairprogram/AppIcon.icns ($VARIANT)"
