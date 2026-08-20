#!/bin/zsh
# Build the Rust core for all Apple targets and regenerate + install the
# UniFFI Swift bindings. The lib and bindings carry matching API checksums,
# so they must always ship together — run this instead of a bare `cargo build`.
set -e
cd "$(dirname "$0")"
# CI sets this to skip the device slice, which a simulator test never links.
# Anything that ships must leave it unset. The host build is not optional
# either way: uniffi-bindgen reads the API out of the dylib it produces.
SIMULATOR_ONLY=${SIMULATOR_ONLY:-0}

~/.cargo/bin/cargo build --release --target aarch64-apple-darwin
~/.cargo/bin/cargo build --release --lib --target aarch64-apple-ios-sim
if [[ $SIMULATOR_ONLY == 0 ]]; then
  ~/.cargo/bin/cargo build --release --lib --target aarch64-apple-ios
fi
# All three stay present so the search paths resolve the same either way.
mkdir -p lib/macosx lib/iphoneos lib/iphonesimulator
cp target/aarch64-apple-darwin/release/liblush_core.a lib/macosx/
cp target/aarch64-apple-ios-sim/release/liblush_core.a lib/iphonesimulator/
if [[ $SIMULATOR_ONLY == 0 ]]; then
  cp target/aarch64-apple-ios/release/liblush_core.a lib/iphoneos/
fi
~/.cargo/bin/cargo run --release --target aarch64-apple-darwin --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/liblush_core.dylib \
  --language swift --out-dir bindings
mkdir -p bindings/include
cp bindings/lush_coreFFI.h bindings/include/lush_coreFFI.h
cp bindings/lush_coreFFI.modulemap bindings/include/module.modulemap
cp bindings/lush_core.swift ../Shared/LushCore.swift
echo "rust libs (macosx, iphoneos, iphonesimulator) + swift bindings in sync"
