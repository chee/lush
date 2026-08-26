# Lush — agent notes

## Threading

Keep the main thread clear. Prefer async APIs. When a synchronous call can't be avoided, use `Task.detached` to move it off the main actor.

**EventKit**: `EKEventStore.events(matching:)` is synchronous and slow. Always call it in a `Task.detached`, passing the store reference in:

```swift
let store = self.store
let items = await Task.detached {
    store.events(matching: predicate).compactMap(MyItem.init)
}.value
```

`predicateForEvents`, `calendars(for:)`, and `fetchReminders` (callback-based) are fine on the main actor. The blocking `events(matching:)` is the one to watch.

The same principle applies anywhere a synchronous call might block: file I/O, JSON decoding of large payloads, image processing, etc. If it's not instant, it belongs off the main actor.

**Rust/FFI calls** through `Core` are already async — keep them in `Task.detached` or the async FFI wrappers that already exist.

## New notes are instant

Making a new note as-instantly-as-can-be is a primary feature of this
application. Nothing on the create path — cmd+N, widgets, shortcuts, quick
actions, the dock tile — may wait on a doc open, a config read, or the
network. Everything the path needs is cached and read synchronously on the
main actor: folder settings are indexed by folder url in
`NotesModel.folderSettings` (persisted through `FolderSettingsStore`), and the
inbox url is persisted in UserDefaults (`NotesModel.inboxUrlKey`) so the
target folder and its formatting are known before login or the config doc
have settled. `createNoteNow` then builds the doc, its opening spans and the
folder entry in one call. `bootLog` traces every millisecond of cmd+N; keep
it that way — anything new the create path needs must be cached the same way,
never fetched at creation time.

## Architecture

- `NotesModel` — `@MainActor @Observable`, owns the Rust `Core`
- `AgendaStore` — `@MainActor @Observable`, owns `EKEventStore`
- Views get model access via `@Environment`

## Storage and sync

**`@automerge/automerge-repo@2.6.0-subduction.48` is the reference implementation.**
Anything touching the sedimentree write path — what gets stored as a loose
commit vs a fragment, when to bundle, how saves are batched — should be checked
against it before inventing an approach. It has already hit most of these
problems.

```
npm pack @automerge/automerge-repo@2.6.0-subduction.48
```

The parts that matter are `src/subduction/source.ts` (`#saveNewCommits` is our
`ingest`) and `src/subduction/storage.ts`.

What it establishes:

- **Automerge core owns the compaction policy.** Mirror the fragment view the
  doc reports — level 0 becomes a loose commit, level >= 1 becomes a fragment —
  and never hand-build an `AutomergeFragment`. A fragment automerge did not
  create has a head it will never report, which puts our sedimentree and the
  server's out of step. Automerge forms fragments on its own during ordinary
  editing and the loose tail stays bounded; `bench_natural_fragment_formation`
  measures it.
- **Enumerating fragment metadata is cheap; bundling is not.** `doc.fragments()`
  is a few ms even on a large note (JS `getFragmentMetadata` calls straight into
  it), but bundling is O(n) per item. Filter against what is already stored
  first and bundle only what survives. Getting this backwards is what makes a
  save O(the note's history).
- **Don't read only level 0 to save time.** A change whose own `fragment_level`
  is >= 1 never appears in the loose tail, so a level-0 pass silently misses
  records that have to be stored.

**Benchmark in release.** A debug build inflates automerge by 10-15x and will
send you chasing a scaling problem that isn't there. The `bench_*` tests in
`core/src/repo.rs` are `#[ignore]`d; run them with
`cargo test --release --lib bench_ -- --ignored --nocapture`.

## Reading note content

The search index (`search.sqlite3`) is the single extraction stage. The indexer
listens for `DocChanged`, opens the doc once (`indexed_doc` in
`core/src/search.rs`), writes one row, and `DocIndexed` fires once the row is
fresh.

Anything that wants a note's content — previews, Spotlight, embeddings, maps —
reads the index row (`core.noteContent(url:)` / `SearchIndex::indexed_note`)
and subscribes to `DocIndexed`. Don't open docs to read them; `DocChanged` is
the indexer's cue, not yours, and fires before the row catches up.

Need something the row doesn't carry? Add it to the index first: a column, its
extraction in `indexed_doc`, and its comparison in `upsert`'s no-op check so
existing rows backfill on the next crawl. Then read it back like everything
else.

## Style

Follow the existing code — no comments, no ceremony, plain functions over classes where they fit.
