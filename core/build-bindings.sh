#!/bin/zsh
# Build the Rust core for all Apple targets and regenerate + install the
# UniFFI Swift bindings. The lib and bindings carry matching API checksums,
# so they must always ship together — run this instead of a bare `cargo build`.
set -e
cd "$(dirname "$0")"
~/.cargo/bin/cargo build --release --target aarch64-apple-darwin
#~/.cargo/bin/cargo build --release --target x86_64-apple-darwin
~/.cargo/bin/cargo build --release --lib --target aarch64-apple-ios
~/.cargo/bin/cargo build --release --lib --target aarch64-apple-ios-sim

# Weaken _rust_eh_personality in each arch-specific static lib so the
# linker does not complain about a duplicate strong symbol when both
# liblush_core.a and libpatchwork_server.a (which also bundles Rust std)
# are linked into the same binary.  Must be done on the thin archives
# before lipo wraps them in a fat-binary container.
# llvm-objcopy processes each archive member in place, avoiding any
# name-collision risk from manual ar -x extraction.
for arch_lib in \
    target/aarch64-apple-darwin/release/liblush_core.a \
    target/aarch64-apple-ios/release/liblush_core.a \
    target/aarch64-apple-ios-sim/release/liblush_core.a
do
    xcrun llvm-objcopy --weaken-symbol=_rust_eh_personality "$arch_lib"
done

mkdir -p lib/macosx lib/iphoneos lib/iphonesimulator
# lipo -create \
#   target/aarch64-apple-darwin/release/liblush_core.a \
#   target/x86_64-apple-darwin/release/liblush_core.a \
#   -output lib/macosx/liblush_core.a
lipo -create \
  target/aarch64-apple-darwin/release/liblush_core.a \
  -output lib/macosx/liblush_core.a
cp target/aarch64-apple-ios/release/liblush_core.a lib/iphoneos/
cp target/aarch64-apple-ios-sim/release/liblush_core.a lib/iphonesimulator/
~/.cargo/bin/cargo run --release --target aarch64-apple-darwin --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/liblush_core.dylib \
  --language swift --out-dir bindings
mkdir -p bindings/include
cp bindings/lush_coreFFI.h bindings/include/lush_coreFFI.h
cp bindings/lush_coreFFI.modulemap bindings/include/module.modulemap
cp bindings/lush_core.swift ../Shared/LushCore.swift
echo "rust libs (macosx, iphoneos, iphonesimulator) + swift bindings in sync"
