#!/usr/bin/env bash
# Builds onramp-core and packages it for the Swift app:
#   app/Frameworks/onramp_core.xcframework  (static lib + C header + modulemap)
#   app/Sources/onramp/Generated/onramp_core.swift  (UniFFI bindings)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="$ROOT/app/Frameworks/onramp_core.xcframework"
GEN="$ROOT/app/Sources/onramp/Generated"
TMP="$CORE/target/uniffi"

cd "$CORE"
export MACOSX_DEPLOYMENT_TARGET=14.0 # the app's minimum (Package.swift); C grammars follow it too
# Apple Silicon + Intel, joined into one universal static library.
cargo build --release --target aarch64-apple-darwin --lib -q
cargo build --release --target x86_64-apple-darwin --lib -q
mkdir -p target/universal
lipo -create target/aarch64-apple-darwin/release/libonramp_core.a target/x86_64-apple-darwin/release/libonramp_core.a \
  -output target/universal/libonramp_core.a

rm -rf "$TMP" && mkdir -p "$TMP/headers" "$GEN"
cargo run -q --release --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/libonramp_core.dylib \
  --language swift --out-dir "$TMP"

mv "$TMP"/*.h "$TMP/headers/"
mv "$TMP"/*.modulemap "$TMP/headers/module.modulemap"
mv "$TMP"/*.swift "$GEN/"

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library target/universal/libonramp_core.a \
  -headers "$TMP/headers" \
  -output "$OUT" >/dev/null
echo "built $OUT"
