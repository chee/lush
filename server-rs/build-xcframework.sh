#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
source "$HOME/.cargo/env"

LIB=libpatchwork_server.a
STAGING=target/xcframework-staging
KIT=../PatchworkServerKit

cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin

# Bindgen reads metadata out of a host dylib
cargo build --release --features cli
cargo run --release --features cli --bin uniffi-bindgen -- generate \
  --library target/release/libpatchwork_server.dylib \
  --language swift --out-dir target/bindings

rm -rf "$STAGING"
mkdir -p "$STAGING/headers" "$STAGING/macos-universal"
cp target/bindings/patchwork_serverFFI.h "$STAGING/headers/"
cp target/bindings/patchwork_serverFFI.modulemap "$STAGING/headers/module.modulemap"
lipo -create \
  target/aarch64-apple-darwin/release/$LIB \
  target/x86_64-apple-darwin/release/$LIB \
  -output "$STAGING/macos-universal/$LIB"

rm -rf "$KIT/Artifacts/PatchworkServerFFI.xcframework"
mkdir -p "$KIT/Artifacts"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/$LIB -headers "$STAGING/headers" \
  -library target/aarch64-apple-ios-sim/release/$LIB -headers "$STAGING/headers" \
  -library "$STAGING/macos-universal/$LIB" -headers "$STAGING/headers" \
  -output "$KIT/Artifacts/PatchworkServerFFI.xcframework"

mkdir -p "$KIT/Sources/PatchworkServerKit/Generated"
cp target/bindings/patchwork_server.swift "$KIT/Sources/PatchworkServerKit/Generated/"
echo "done: $KIT/Artifacts/PatchworkServerFFI.xcframework"
