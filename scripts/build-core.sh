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
export MACOSX_DEPLOYMENT_TARGET=14.0 # the app's minimum (Package.swift); C grammars follow it too
# Apple Silicon + Intel, joined into one universal static library.
cargo build --release --target aarch64-apple-darwin --lib -q
cargo build --release --target x86_64-apple-darwin --lib -q
mkdir -p target/universal
lipo -create target/aarch64-apple-darwin/release/libpairprogram_core.a target/x86_64-apple-darwin/release/libpairprogram_core.a \
  -output target/universal/libpairprogram_core.a

rm -rf "$TMP" && mkdir -p "$TMP/headers" "$GEN"
cargo run -q --release --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/libpairprogram_core.dylib \
  --language swift --out-dir "$TMP"

mv "$TMP"/*.h "$TMP/headers/"
mv "$TMP"/*.modulemap "$TMP/headers/module.modulemap"
mv "$TMP"/*.swift "$GEN/"

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library target/universal/libpairprogram_core.a \
  -headers "$TMP/headers" \
  -output "$OUT" >/dev/null
echo "built $OUT"
