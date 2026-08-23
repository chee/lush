# Codebase audit — 2026-08-23

Full-tree review for real defects: the Rust core, the Swift model/sync layer,
the Swift UI/feature layer, server-rs + web, and the extensions/widgets/tests.
Every finding was verified against the surrounding code; hypotheticals and
style nits were dropped. `file:line` references are against this commit's
parent tree.

## High severity

### 1. OAuth loopback callback accepts requests with no `state`
`lush/OpenRouterAuthentication.swift:164`

```swift
guard isCallback, let code, state == nil || state == self.expectedState else { ... }
```

A `state` value is generated and sent to OpenRouter, but the callback handler
accepts any request that simply omits the parameter, so the CSRF check is
decorative. While a sign-in is pending, anything that can reach the loopback
port — another local process, or a drive-by page issuing
`GET http://127.0.0.1:PORT/openrouter?code=…` across the ephemeral port range —
completes the flow with an attacker-chosen authorization code (session
fixation: the user ends up keyed to the attacker's account). Fix: require
`state == self.expectedState`, no nil escape.

### 2. Concurrent `drainSharedIntake` runs double-import and race cleanup
`lush/NotesModel.swift:3710`

`drainSharedIntake()` has no reentrancy guard and is triggered from five
independent places: `ContentView` `.task` at launch (`ContentView.swift:360`,
`:475`), scene-phase handlers (`:357`, `:472`), the `lush://share` URL route
(`:608`, fired by the extensions), and the 30-second maintenance loop
(`NotesModel.swift:1482`). On a cold-start share, the launch `.task` and the
URL-route drain run concurrently; each builds its own `HandoffJournal` from
`progress.json` (`Shared/SharedIntake.swift:88-124`) with an empty in-memory
`completed` set, and `importToInbox` suspends across `await importFileEntries`
(`NotesModel.swift:3765`), so the drains interleave: the same file imports
twice, and whichever drain finishes first calls `cleanupHandoff()`
(`:3731`), deleting the directory out from under the other mid-copy. The
journal deduplicates across process restarts only. Fix: a single in-flight
task/flag on `NotesModel` (coalesce concurrent drains).

### 3. Share/import pipeline does file I/O and blocking FFI on the main actor
`lush/NotesModel.swift:3884-3922`, `:3986-4002`, `:3683-3688`, `:3801-3809`

`importSingleFileEntry` reads whole files with `Data(contentsOf:)` and pushes
the bytes through synchronous uniffi calls (`core.createAssetIn` /
`createAsset` — plain `rustCallWithError`, not async) on `@MainActor`
`NotesModel`; `importFileAsNote`/`noteSpans(fromFile:)` add `String(contentsOf:)`
and an RTF→HTML `NSAttributedString` conversion on main. Sharing a video or a
folder of photos freezes the UI for the duration and can trip the iOS watchdog.
The intended pattern already exists next door: `importFileForShortcut` wraps
the same `createAssetIn` in `Task.detached` (`:1908-1916`).

### 4. `loadContextMeta` opens docs instead of the index row, and never invalidates
`lush/NotesModel.swift:1598-1618`

Every visible note row (`ContentView.swift:2269` → rendered in
`FolderViews.swift:246,270`) calls `core.noteSpansJson(url:)` and decodes the
full span list just to read `created`/`location`/`weather`/`nowPlaying` —
exactly what CLAUDE.md forbids ("read the index row… don't open docs"), and
without the `openNote`/`closeNote` pinning other doc readers use. Scrolling a
sidebar materializes every note's doc. Staleness on top: `docChanged`
(`:1669-1675`) clears the thumbnail but never `row.contextMeta`, and
`loadContextMeta` guards on `contextMeta == nil`, so metadata rewritten later
(location fix, weather, sync from another device) never refreshes until
relaunch. Fix: add these fields to the search index (per CLAUDE.md's recipe)
and clear `contextMeta` in `docChanged`.

### 5. Dragged file fully read on the main thread on every drag-over tick
`lush/ScratchpadEditing.swift:249-294`

`PadDropTarget.Drop.operation(_:)` — called from both `draggingEntered` and
`draggingUpdated` — calls `file(from:)`, which does `Data(contentsOf: url)`
plus TIFF→PNG re-encoding. `draggingUpdated` fires continuously, so hovering a
large file over the pad re-reads it on the main thread repeatedly before the
drop. Hover only needs pasteboard types to answer `.copy`; read bytes (off
main) in `performDragOperation` only.

## Medium severity

### 6. Resident docs never forget announced server heads on sync failure
`core/src/repo.rs:2224-2235`

For a resident doc, `on_remote_heads` inserts the announced `heads_set` into
`last_server_heads` before its forced sync has succeeded, and nothing rolls it
back on failure — unlike the untracked-doc branch (`:2180-2198`), which removes
the entry so the server's next identical announcement retries. If all
`HEAL_MAX_ATTEMPTS` rounds fail (server hiccup), the re-announcement of the
same heads is dropped by the guard at `:2201` and the doc stays stale until the
server's heads change or the connection bounces. Mirror the untracked branch's
"forget on failure" behavior.

### 7. Re-entering the background skips the durability flush
`lush/BackgroundSync.swift:106-109`

`didEnterBackground` early-returns when the previous background assertion is
still live. Background → brief foreground (user types) → background again
within the first stint's ~20 s: no new flush is scheduled, and when the first
task finishes it parks the core, leaving the interlude's edits behind the save
debounce — the exact suspend-kill data-loss window the file's own comment
(`:129-132`) describes. Re-run `flushPendingWrites` on re-entry.

### 8. `HandoffJournal.mutate` reports the previous flush's durability
`Shared/SharedIntake.swift:132-144`

`ok = !failed` is computed before the flush it just scheduled runs, so the
first failing journal write is reported as success. `importToInbox` trusts
that return (`NotesModel.swift:3805`): a note is created, `markHandoffCreatedUrl`
"succeeds" without reaching disk, and a retried entry creates a duplicate note
— the very case the guard exists for. The guard can only fire from the second
failing mutate on.

### 9. Share/export renders RTF/PDF and writes files on the main actor
`lush/NoteShare.swift:32-68` with `lush/NoteExporter.swift:153-193`, `:29-70`

`NoteShare.fileURL` (the `ShareLink` closure) runs `RichText.attributed(from:)`,
full CoreText pagination for PDF, and `data.write(to:)` synchronously on main;
`NoteExporter.exportAndSave` likewise decodes and renders the full note on
main. "Share As → PDF" on a long note freezes the UI for the whole layout+write.

### 10. Attachment ingestion reads whole files synchronously on main
`lush/RichTextEditor.swift:5372` (paste), `:4303` (open panel),
`lush/ContentView.swift:4268` (iOS file importer),
`lush/MediaViews.swift:174,189,694,770` (`AVAudioPlayer(contentsOf:)` in tap
handlers, `Data(contentsOf:)` of trimmed exports)

Same class as #3: attach/paste of a large video or audio stalls the UI for the
read. The `Task.detached` pattern already used in these files applies.

### 11. Note-chat transcripts persist in UserDefaults forever
`lush/NoteChat.swift:51-71`

Chat turns — including note text and full `spans` JSON of drafted note states —
are stored per note URL under `noteChat.turns.<url>` and cleared only by the
chat panel's trash button. Deleting a note leaves its content in the
preferences plist indefinitely, and the plist grows without bound. Clear the
key on note deletion (and consider moving transcripts out of UserDefaults).

### 12. Failed extension handoff leaks its intake directory forever
`Common/SharedHandoff.swift:62,155` with
`LushShareExtension/ShareViewController.swift:28-30`,
`LushFinderAction/FinderActionRequestHandler.swift:11-13`

`SharedHandoff.write` creates the directory first; if `loadItems` throws
mid-copy, the extension only calls `cancelRequest` — partial copies stay in
the app group with no `payload.json`, and the app-side drain skips (never
deletes) such entries (`NotesModel.swift:3723-3725`). Orphans accumulate
permanently. Delete the directory in the throwing path (or have the drain
garbage-collect stale payload-less entries).

### 13. Pinned-URL cache can serve stale content through headless child links
`web/src/resolver.ts:126-135, 185-207`; `web/src/handoff.ts:47`;
`web/public/sw.js:79`

`isPinned` checks only the base doc's heads, but `resolvePath` follows folder
`DocLink`s to child URLs as stored — normally headless. A head-pinned folder
resolving to bytes from a mutable child gets cached indefinitely (resolver
`cachePut` and the SW cache both treat it as immutable); later edits to the
child never surface. The immutability assumption must cover the whole resolved
chain, or pinned-cache only the leaf when the leaf itself is pinned.

## Low severity

- **`core/src/api.rs:2183-2196, 2351-2361, 2703-2710`** — `note_preview` /
  `note_title` / `note_modified` open or rebuild docs to answer questions the
  `search_docs` row already carries; `note_title`/`note_modified` go through
  `read_doc` → `open_local`, inflating the resident set (CLAUDE.md violation).
- **`core/src/api.rs:542-549` + `core/src/repo.rs:3000-3010, 2715-2721`** — a
  transient storage-read failure on open leaves an empty resident doc, still
  emits `DocChanged`, and the indexer then deletes the note's search row,
  FTS row, links, and embeddings even though the on-disk data is intact.
  Distinguish "unreadable right now" from "not indexable".
- **`core/src/search.rs:210-273`** — every migration `ALTER TABLE` swallows
  all errors (`let _ =`), not just "duplicate column"; a SQLITE_BUSY/disk-full
  failure leaves a column missing and every subsequent `upsert` silently
  failing for the process's life. Match the duplicate-column error, propagate
  the rest.
- **`core/src/api.rs:660-686`** — `set_delegate` spawns a forwarding loop per
  call with no replacement; a second call (scene reconnect) delivers every
  event twice and keeps the old delegate's object graph alive.
- **`core/src/repo.rs:1779-1790, 3086-3091`** — with `apply_incoming` off,
  echoes of the doc's own saves land in `deferred_applies`, emitting phantom
  "changes waiting in the future" events and blocking eviction of every edited
  doc — degrading memory relief exactly in long paused sessions.
- **`lush/SpanDoc.swift:747-762, 880`** — `AssetCache.storeImage` decodes and
  writes full asset bytes synchronously on the main actor (callers:
  `PadStore.addFile`, `fetchAssets`, `snapshotAssetCache`); the decode path
  (`ensureDisplayImage`) already hops off main, the write path should too.
- **`lush/LushAgentServer.swift:139-141`** — the `GET /v1/note` handler calls
  synchronous `core.closeNote` on the main actor (every other handler
  detaches); minor: the bearer-token compare at `:91` isn't constant-time.
- **`web/src/bytes.ts:1-7`** — `hexToBytes` silently truncates odd-length input
  and maps non-hex pairs to 0; a malformed `signerSeedHex` yields a silently
  different signer identity instead of a loud failure.
- **`web/public/sw.js:4, 155-170`** — opaque (`status: 0`) cross-origin
  responses are cached and served on network failure with no revalidation; a
  cached origin error page can be served offline as if valid.
- **`web/src/flush.ts:40-49`** — the `wake` resolver is reassigned only inside
  each loop iteration, so a `subduction-remote-heads` event in the gap hits an
  already-resolved promise and costs up to one 100 ms poll (latency only).
- **`LushWidget/LushWidget.swift:118-120, 162`** — placeholder builds three
  snapshots all with `url: ""` while the view uses `ForEach(id: \.url)`;
  duplicate identities mean the gallery placeholder typically renders one row.
- **`LushWidget/LushWidget.entitlements`** — missing
  `com.apple.security.app-sandbox`, unlike every sibling extension; fails App
  Store validation / can be refused at load.
- **`Common/SharedHandoff.swift:104-107`** — shared images are always named
  `image-N.png` with raw provider bytes (JPEG/HEIC included); downstream MIME
  derives from the extension, mislabeling the data.
- **`PatchworkServerKit/.../ServerController.swift:47-49, 60`** — synchronous
  Rust FFI (`serverIrohPeers`, `serverStop`) on the main actor, against the
  CLAUDE.md FFI rule; `stop()` also leaves `irohNodeId`/`friends` populated.
- **`LushTests/SpanDocTests.swift:189`** — the blank-extra assertion only
  rejects keys saved verbatim with leading spaces; a trim-then-save regression
  storing under `""` passes. Add `XCTAssertNil(saved.attrs[""])`.

## Checked and found sound

The sedimentree write path honors the CLAUDE.md invariants (`ingest`
enumerates all fragment levels, filters against stored heads before bundling,
never hand-builds fragments; outbox truncation held back on bundle failure).
The outbox durability protocol survives the truncate-vs-keystroke,
evict-vs-edit, and debounce-abort races. `server-rs` key persistence is atomic
and 0o600; wire decode is bounded and panic-free on hostile bytes. Search SQL
parameter numbering, FTS term construction, and LIKE escaping are correct.
EventKit's blocking `events(matching:)` is correctly detached
(`Agenda.swift:580`). The handoff payload-written-last protocol prevents
half-imports of in-progress shares; the encoder/decoder pairs between app and
extensions match. Credentials go through the Keychain; the agent server is
loopback-only with a per-launch token, bounded bodies, and a path-traversal
guard. `NoteChatEdits.apply` op merging is index-safe; view-lifecycle tasks
cancel cleanly; the hand-rolled CBOR codec is length-bounded and
overflow-safe.
