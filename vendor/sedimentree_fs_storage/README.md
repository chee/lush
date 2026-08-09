# sedimentree_fs

Filesystem-based storage backend for Sedimentree.

## Lush fork

Vendored from `inkandswitch/subduction` at rev `9c0fbfd06bd499d4a8b53548788119d33af0d1ec`,
with one change: the `SedimentreeId` cache is scanned from `trees/` on first use
instead of in `FsStorage::new`.

Upstream's scan costs one `read_dir` per bucket. On a store with ~26k trees that
is ~3.7s, paid synchronously before the app can do anything, and nothing that
opens the storage needs the full set — the callers that do can wait.

The one behaviour difference: a handle can now observe registrations another
handle made on the same root after it was opened, because the snapshot is taken
at first query rather than at open. `failed_single_save_does_not_register_tree_id`
and `failed_batch_does_not_register_tree_id` in `tests/roundtrip.rs` assert
before/after equality of the registered set instead of upstream's
"unregistered beforehand" conformance helper, which relied on that staleness.

## Overview

This crate provides `FsStorage`, a content-addressed filesystem storage implementation
that implements the `Storage` trait from `subduction_core`.

## Storage Layout

```text
root/
├── trees/
│   └── {sedimentree_id_hex}/
│       ├── commits/
│       │   └── {digest_hex}.cbor  ← Signed<LooseCommit>
│       └── fragments/
│           └── {digest_hex}.cbor  ← Signed<Fragment>
└── blobs/
    └── {digest_hex}               ← raw bytes
```

## Usage

```rust
use sedimentree_fs::FsStorage;
use std::path::PathBuf;

let storage = FsStorage::new(PathBuf::from("./data"))?;
```

## Features

- Content-addressed storage (files named by BLAKE3 digest)
- Atomic writes (write to `.tmp`, then rename)
- CBOR encoding for commits/fragments via minicbor
- Blobs stored as raw bytes
- In-memory cache of `SedimentreeId`s for fast lookup
- Implements both `Storage<Sendable>` and `Storage<Local>` traits

## License

MIT OR Apache-2.0
