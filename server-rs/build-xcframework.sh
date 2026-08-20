#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
source "$HOME/.cargo/env"

LIB=libpatchwork_server.a
STAGING=target/xcframework-staging
KIT=../PatchworkServerKit

# A test run links the simulator slice and nothing else, so CI sets this and
# skips the device and macOS builds — they were most of the build and none of
# the test. Anything that ships must leave it unset.
SIMULATOR_ONLY=${SIMULATOR_ONLY:-0}

cargo build --release --target aarch64-apple-ios-sim
if [[ $SIMULATOR_ONLY == 0 ]]; then
  cargo build --release --target aarch64-apple-ios
  cargo build --release --target aarch64-apple-darwin
fi

# Bindgen reads metadata out of a host dylib
cargo build --release --features cli
cargo run --release --features cli --bin uniffi-bindgen -- generate \
  --library target/release/libpatchwork_server.dylib \
  --language swift --out-dir target/bindings

rm -rf "$STAGING"
mkdir -p "$STAGING/headers"
cp target/bindings/patchwork_serverFFI.h "$STAGING/headers/"
cp target/bindings/patchwork_serverFFI.modulemap "$STAGING/headers/module.modulemap"

# macOS is arm64 only. The core's own macOS lib has been arm64 only for a
# while, so the app could not run on an Intel Mac regardless of what this
# built; the second slice was weight nothing loaded.
slices=(-library target/aarch64-apple-ios-sim/release/$LIB -headers "$STAGING/headers")
if [[ $SIMULATOR_ONLY == 0 ]]; then
  slices+=(-library target/aarch64-apple-ios/release/$LIB -headers "$STAGING/headers")
  slices+=(-library target/aarch64-apple-darwin/release/$LIB -headers "$STAGING/headers")
fi

rm -rf "$KIT/Artifacts/PatchworkServerFFI.xcframework"
mkdir -p "$KIT/Artifacts"
xcodebuild -create-xcframework "${slices[@]}" \
  -output "$KIT/Artifacts/PatchworkServerFFI.xcframework"

mkdir -p "$KIT/Sources/PatchworkServerKit/Generated"
cp target/bindings/patchwork_server.swift "$KIT/Sources/PatchworkServerKit/Generated/"
echo "done: $KIT/Artifacts/PatchworkServerFFI.xcframework"
