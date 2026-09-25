#!/usr/bin/env bash
# Builds pairprogram-core and packages it for the Swift app:
#   app/Frameworks/pairprogram_core.xcframework  (static lib + C header + modulemap)
#   app/Sources/pairprogram/Generated/pairprogram_core.swift  (UniFFI bindings)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="$ROOT/app/Frameworks/pairprogram_core.xcframework"
GEN="$ROOT/app/Sources/pairprogram/Generated"
TMP="$CORE/target/uniffi"

cd "$CORE"
cargo build --release --target aarch64-apple-darwin --lib -q

rm -rf "$TMP" && mkdir -p "$TMP/headers" "$GEN"
cargo run -q --release --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/libpairprogram_core.dylib \
  --language swift --out-dir "$TMP"

mv "$TMP"/*.h "$TMP/headers/"
mv "$TMP"/*.modulemap "$TMP/headers/module.modulemap"
mv "$TMP"/*.swift "$GEN/"

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-darwin/release/libpairprogram_core.a \
  -headers "$TMP/headers" \
  -output "$OUT" >/dev/null
echo "built $OUT"
