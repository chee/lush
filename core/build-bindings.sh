#!/bin/zsh
# Build the Rust core for all Apple targets and regenerate + install the
# UniFFI Swift bindings. The lib and bindings carry matching API checksums,
# so they must always ship together — run this instead of a bare `cargo build`.
set -e
cd "$(dirname "$0")"
~/.cargo/bin/cargo build --release
~/.cargo/bin/cargo build --release --lib --target aarch64-apple-ios
~/.cargo/bin/cargo build --release --lib --target aarch64-apple-ios-sim
mkdir -p lib/macosx lib/iphoneos lib/iphonesimulator
cp target/release/librichtext_core.a lib/macosx/
cp target/aarch64-apple-ios/release/librichtext_core.a lib/iphoneos/
cp target/aarch64-apple-ios-sim/release/librichtext_core.a lib/iphonesimulator/
~/.cargo/bin/cargo run --release --bin uniffi-bindgen -- generate \
  --library target/release/librichtext_core.dylib \
  --language swift --out-dir bindings
mkdir -p bindings/include
cp bindings/richtext_coreFFI.h bindings/include/richtext_coreFFI.h
cp bindings/richtext_coreFFI.modulemap bindings/include/module.modulemap
cp bindings/richtext_core.swift ../richtext/RichtextCore.swift
echo "rust libs (macosx, iphoneos, iphonesimulator) + swift bindings in sync"
