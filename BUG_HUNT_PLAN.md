# Bug hunt fix plan

From a 10-dimension sweep (Swift threading, memory, editor, app views, launch, Rust automerge/sedimentree, Rust hygiene, FFI bridge, web/JS, duplication). 100 findings confirmed by adversarial re-verification against the code; overlapping reports merged below. Phases are ordered by user harm: data loss first, then jank, then waste, then structure.

## Phase 1 — Data integrity & correctness

Things that lose, corrupt, or wrongly overwrite user data, or break sync.

- [x] **Failed fragment ingest silently drops edits** — `core/src/repo.rs:2018`. When `doc.fragments()` panics (known automerge issue the code already guards elsewhere), `save_doc_now` logs and returns `Ok(false)`; nothing retries, shutdown doesn't flush, edits live only in memory. Fix: on ingest failure fall back to `stage_doc(id)` (outbox path already merges back via `open_local`), and keep the doc in a dirty set that `shutdown()`/`drop_doc()` retry.
- [x] **FFI write paths skip `guarded()`** — `core/src/api.rs:1629` and 12 siblings (`rename_note`, `rename_entry`, `move_entry`, `remove_entry`, `create_subfolder`, `create_note`, `create_note_doc`, `link_note_to_folder`, `delete_note`, `create_asset`, `update_asset_vision`, `update_asset_ml`, `create_script_in`). The same panic `guarded()` exists for unwinds into uniffi and aborts the app. Fix: move the `catch_unwind` into `Repo::change_doc`/`change_doc_at` so every mutation closure is covered once.
- [x] **Snapshot load failure becomes an empty doc that can overwrite the real one** — `lush/NotesModel.swift:1678`. `spansSnapshot(for:)` maps any error to `spansJson: "[]", heads: []`, caches it into the launch snapshot, and the editor marks it authoritative; typing then whole-doc-replaces real content on every device. Fix: distinguish "not available yet" (loading state), skip `cacheLaunchSnapshot` on the fallback, refuse local writes while `heads` is empty and the doc never loaded.
- [ ] **Pad writes can apply out of order** — `lush/Scratchpad.swift:146`. `add`/`move`/`setData`/`remove` each fire independent `Task.detached` with `try?`; setData can land before the add it targets and the error is swallowed. Fix: serialize pad writes per pad (chain like `chainedNoteWrite`, or one actor/AsyncStream).
- [ ] **Stale `refreshNotes` publishes over newer trees** — `lush/NotesModel.swift:973`. Unversioned concurrent detached walks; slow old walk can overwrite a fresh one. Fix: generation counter or cancel-and-replace single in-flight refresh.
- [ ] **Resync nudge defeated by `last_synced_local_heads` skip** — `core/src/repo.rs:1794`. The one path meant to pull newly announced remote heads early-returns whenever the local doc is idle; remote edits arrive only after a local edit or reconnect. Fix: use `request_sync_forced` in the still-missing branch of `on_remote_heads`.
- [ ] **`waitForStartup` timeout can't fire; iOS BG task hangs to force-expiry** — `lush/SmartNotebooks.swift:191` + `lush/NotesModel.swift:1157`. Cancelling a task parked on `withCheckedContinuation` never resumes it; `BackgroundSync.run` then never calls `setTaskCompleted`. Fix: `withTaskCancellationHandler` that removes+resumes the continuation; also resume `startupWaiters` on shutdown.
- [ ] **Create/link errors swallowed → orphaned notes** — `lush/NotesModel.swift:1420` (also `:708`, `:2666`, `lush/NoteChatTools.swift:90`). `try? core.linkNoteToFolder` failure leaves a doc referenced by no folder, vanishing from the sidebar. Fix: propagate to the existing catch (sets status) or retry the link on next `docChanged`.
- [ ] **Any search-DB open error deletes the database** — `core/src/search.rs:84`. `SQLITE_BUSY` from another process (helper/extension) is treated as corruption; files unlinked under a live connection. Fix: delete only on `SQLITE_CORRUPT`/`SQLITE_NOTADB`; retry/propagate busy.
- [ ] **Title derivation exists 3× with divergent rules** — `lush/SpanDoc.swift:1685`, `lush/RichTextEditor.swift:1213`, `core/src/shapes.rs:302`. The debounced save recomputes with the buggy variant and renames the folder entry, undoing the fixed title the splice path wrote. Fix: make the run-accumulating `titleFromStorage` logic the one Swift implementation; align `title_from_spans` in Rust (same first-line + 60 cap).
- [ ] **Recorder toggle leaves mic recording invisibly, leaks repeating Timer + temp file** — `lush/AudioRecorder.swift:42` (toggle sites `lush/ContentView.swift:3078`, `lush/LushApp.swift:313`, `lush/RichTextEditor.swift:4853`). Fix: guard `start()` on `isRecording`, `deinit { timer?.invalidate() }`, stop the recorder when hiding the bar.
- [ ] **Handoff caches unpinned automerge URLs; SW serves them cache-first forever** — `web/src/handoff.ts:47` + `web/public/sw.js:53`. Only head-pinned URLs are content-addressed (rule already encoded in `resolver.ts:127`). Fix: `cache.put` only when the URL carries heads; reply `type: "response"` for unpinned resolves.
- [ ] **Native scheme handler double-decodes paths** — `lush/PatchworkView.swift:895`. `url.path` is already decoded; JS decodes again — filenames with `%` become unservable. Fix: pass `percentEncodedPath`.
- [ ] **Index-task cleanup clobbers newer task handles** — `lush/NotesModel.swift:2288` (also `:2307`, `:2258`). Finishing old task nils the new task's entry; debounce breaks, duplicate index work. Fix: compare the stored task to self before nil-ing; re-check `Task.isCancelled` after awaits.

## Phase 2 — Main-thread unblocking (Swift)

One pattern throughout: file I/O / sync FFI / heavy codec work on the main actor. Each fix is the CLAUDE.md `Task.detached` pattern already used correctly elsewhere in the same files.

- [ ] **File import pipeline** — `lush/NotesModel.swift:2977` (`importFiles`), `:2841` (`importAsNewNote`), `:2910` (`importToInbox`), `:3020` (`importFileAsNote` RTF conversion), `:3044` (directory enumeration), `:3066` (`Data(contentsOf:)` + sync `createAsset`). `createAsset:2332` and `importAppleNotes:2479` already do this correctly — mirror them.
- [ ] **Note export** — `lush/NoteExporter.swift:69–109`. Asset writes + `/usr/bin/zip` with `waitUntilExit` on main. Detach; hop back only for the save panel.
- [ ] **Editor attach/paste/copy media** — `lush/RichTextEditor.swift:3481` (attach panel read), `:4133` (paste/drop reads), `:4572` (iOS copy reads + `pngData()` re-encode), `:893` (`mediaFile` full-asset write; callers `:806`, `:870`, `:3520`), `:796`/`:3501` (`PImage(data:)` decode). Detach reads/writes/decodes; for iOS copy prefer lazy `NSItemProvider` file representations.
- [ ] **HTML paste WebKit importer on main** — `lush/RichTextClipboard.swift:171` (call sites `RichTextEditor.swift:3894`, `:4621`). Convert off the paste path or bound input size.
- [ ] **Widget snapshot I/O per refresh** — `lush/NotesModel.swift:1181`, called 2× per `refreshNotes` (`:1000` first with empty previews, `:1029`), plus docChanged debounce and `buildTree`. Fix: drop the first call, snapshot state on main, do read/compare/encode/write in a debounced detached task, keep last-written bytes in memory to skip the file read.
- [ ] **Launch snapshot: dead payload decoded on main at boot** — `lush/NotesModel.swift:207`/`:492`/`:3206`. Only `noteSnapshots` (capped 8) + `selectedNoteUrl` are ever read; previews/thumbnails/folderTree are dead weight encoded on every save and decoded synchronously in `init`. Fix: strip the struct to the two used fields; decode off-main and hydrate.
- [ ] **`startOnce` blocking set-calls** — `lush/NotesModel.swift:584`. `setApplyIncoming`/`setSendChanges` block main during startup; the same calls are detached at `:47`/`:66`. Mirror that.
- [ ] **Helper intake** — `LushHelper/HelperSync.swift:192`. Full file read + blocking `createAssetIn` on the helper's main actor from the poll loop. Detach the intake loop.
- [ ] **Keychain read per embed load** — `lush/PatchworkView.swift:902`. `SecItemCopyMatching` on main for every embed webview. Cache the seed after one off-main read.
- [ ] **Audio trim readback** — `lush/MediaViews.swift:752`. Detach the `Data(contentsOf:)`.
- [ ] **EventKit `calendarItems` lookup on main** — `lush/Agenda.swift:333`. Same class as the documented `events(matching:)` rule; detach with the store passed in (pattern at `:464`).

## Phase 3 — Editor hot paths (typing latency)

- [ ] **Code-block highlighting O(run²) per keystroke** — `lush/CodeHighlight.swift:218` + `lush/ListMarkerLayoutFragment.swift:854` + `lush/RichTextEditor.swift:615`, `:2490`. Each fragment re-tokenizes the whole run; selection change invalidates 4×. Fix: cache tokens per run keyed by edit generation; fragments read the cached list.
- [ ] **Ordered-list renumbering O(n²)** — `lush/ListMarkerLayoutFragment.swift:309`, `:733`, `:838`. Fix: one forward pass per invalidation computing all ordinals, cached by paragraph location.
- [ ] **Remote change / note open rebuilds the document 2–3×** — `lush/RichTextEditor.swift:1009` (and `:707`, `:714`, `:724`). Trailing `apply(spans:)` runs even when nothing was fetched and nothing changed; each apply collapses the user's selection. Fix: `fetchMissingAssets` returns whether it populated the cache; re-apply only then.
- [ ] **Table/columns re-measure every cell per layout query and per body pass** — `lush/TableInline.swift:99`, `:342` (R×C² `measuredHeight`), `ColumnsInline.swift:120`; `embedChanged` also enumerates all `.attachment` runs per keystroke (`TableInline.swift:65`). Fix: cache measured heights on the box, invalidate per-cell on span change; compute row height once per pass.
- [ ] **Presence caret broadcast walks the whole doc per caret settle** — `lush/RichTextEditor.swift:1625`, `:1295`. Two full walks with per-run substring allocation, ~8 Hz while typing. Fix: count scalars without materializing substrings (or cache per-paragraph counts); skip the second walk when the selection is empty.
- [ ] **`pushNow`/`load` decode the previous whole-doc JSON for a log line** — `lush/RichTextEditor.swift:1263` (also `:699`, `:712`). Fix: track the embed count as an Int on the session.
- [ ] **Undo snapshots copy the entire document per formatting op** — `lush/RichTextEditor.swift:2558`. Fix: snapshot the affected paragraph range; cap `levelsOfUndo`.
- [ ] **Outline: per-keystroke full-document scan in body** — `lush/ContentView.swift:3559` + `lush/RichTextEditor.swift:626`, `:1474`. `docVersion` bumps per edit; body calls `outlineItems()` synchronously. Fix: debounced `.task(id: docVersion)` into `@State` (or incremental outline on EditorCore).

## Phase 4 — Rust core: async hygiene & FFI surface

- [ ] **Sync uniffi methods park the caller up to 60 s** — `core/src/api.rs:946` (`login_account`), `:1059`, `:2304`, `:2335`, `:1776`, `:1824`, `:513`, `:618`. Fix: route through `Core::run` (async) like `open_note`/`asset_bytes`.
- [ ] **`reindex_doc` blocks every mutating FFI call on a full read + FTS write** — `core/src/api.rs:336`. Fix: `schedule_index_doc` instead of `block_on`.
- [ ] **rusqlite on tokio workers, up to 500 concurrent index tasks** — `core/src/api.rs:406`, `:1696`; `core/src/search.rs:169`. Fix: `spawn_blocking` or one writer thread fed by a channel; cap prefetch indexing concurrency.
- [ ] **`prefetch_notes` strictly serial, 30 s per unavailable doc** — `core/src/api.rs:1690`. Search gated on `NotesPrefetched` looks empty for minutes. Fix: `ensure_doc` the frontier first, then bounded `FuturesUnordered` waits.
- [ ] **`PrefetchTransport` holds the webview receive path 30 s for unknown docs** — `core/src/repo.rs:218`. New webview-created docs can't sync for ~30 s; other traffic on the socket stalls. Fix: deliver the message immediately, prefetch concurrently.
- [ ] **Accept loop blocks on one client's `tcp.peek`** — `core/src/repo.rs:1524`. A silent connection wedges the local sync server permanently. Fix: spawn per-socket task with a peek timeout.
- [ ] **`stage_doc` full `doc.save()` under the doc lock + blocking fs on the runtime** — `core/src/repo.rs:1097` (also `save_doc_now:2023,2041`, `write_peers:1245`). Fix: `cpu_heavy` the save, drop the lock before writing, `spawn_blocking`/`tokio::fs` the writes; stage incrementally (`save_after`) rather than full compaction per 90 ms debounce.
- [ ] **`open_local` decodes outbox without `cpu_heavy`** — `core/src/repo.rs:2328`. Fix: match the `apply_batch_to_state` pattern three lines up.
- [ ] **`doc_history` decodes full history under the doc lock** — `core/src/api.rs:542`. Opening history stalls typing in that note. Fix: snapshot changes under the lock, build entries outside, wrapped in `cpu_heavy`.
- [ ] **`connect_loop` leaks the listener task when `add_connection` fails** — `core/src/repo.rs:1708`. Fix: abort listener + disconnect transport on that path.
- [ ] **Unbounded stored/heads channels carry cloned blob batches** — `core/src/repo.rs:1363`. Fix: bounded channel (producers are async) or send ids and reload in the consumer.

## Phase 5 — Automerge/sedimentree data-path efficiency

- [ ] **Every local save echoes back through ObservedStorage and re-decodes into the doc** — `core/src/repo.rs:2033` (+ `:2039`). Fix: insert locally ingested blob digests into `state.applied` during `save_doc_now` so the echoed batch filters to empty.
- [ ] **Every data-receiving sync round reloads + rehashes the doc's entire stored blob set** — `core/src/repo.rs:1813`. Fix: rely on the incremental ObservedStorage path; reserve full `stored_batch` reload for explicit repair (`open_local`, error recovery), or track stored digests to skip blob loads.
- [ ] **`pending_change_count`/`pending_doc_history` rehydrate the whole doc per call** — `core/src/repo.rs:1148`, `core/src/api.rs:634`. Fix: diff stored heads vs live heads (`get_missing_deps`/`get_changes(heads)`).
- [ ] **`save_doc` races an in-flight deferred save → duplicate ingest/store** — `core/src/repo.rs:1994`. Fix: per-doc save mutex; mark ingested heads before the awaited store.
- [ ] **`load_blob_batch`: linear dedup + double hashing** — `core/src/repo.rs:1076`. Fix: HashSet; thread digests from `apply_batch_to_state` instead of rehashing.
- [ ] **`PrefetchTransport` decodes every message twice** — `core/src/repo.rs:212`. Fix: sniff the schema header/discriminant (as `wire.rs` does) before full decode.
- [ ] **FTS delete-by-url full-scans per upsert** — `core/src/search.rs:195`. Fix: external-content FTS keyed to rowid, or an indexed rowid mapping.
- [ ] **`search()` re-prepares the links statement per row** — `core/src/search.rs:492`. Fix: `prepare_cached`.

## Phase 6 — Launch & background work reduction

- [ ] **Every `refreshNotes` re-runs the full-corpus prefetch crawl and rewrites the whole FTS index** — `lush/NotesModel.swift:982` + `core/src/api.rs:1673` + `core/src/search.rs:169`. Fix: crawl once per launch (`startOnce` already does); rely on `docChanged` per-doc reindex; make `upsert` skip unchanged heads.
- [ ] **Calendar-link rescan opens + decodes every note every launch** — `lush/NotesModel.swift:2206`. Fix: persist per-note heads/digest next to CalendarLinks; skip unchanged.
- [ ] **Location/geocode/weather started at launch before any consumer** — `lush/ContextTracker.swift:195` (started from `LushApp.swift:402,424,464`); permission prompt at first launch. Fix: start on first consumer (note creation, logline, Places UI); consider significant-change monitoring.
- [ ] **Polling duplicates the `onDocChanged` callback** — `lush/NotesModel.swift:1112`, `LushHelper/HelperSync.swift:108` (helper leaves `onDocChanged` empty and polls instead). Fix: drive from the delegate; keep at most a slow safety-net poll.
- [ ] **`updateSpans` refetches the snapshot it already has per save** — `lush/NotesModel.swift:2043`. Fix: cache `NoteSpansSnapshot(spansJson: json, heads: newHeads)` directly.
- [ ] **Smart notebooks fetch `recentNotes(5000)` per notebook per refresh** — `Shared/SmartNotebookRun.swift:77`. Fix: fetch once per cycle, pass in; skip entirely when query non-empty and no age cutoff.
- [ ] **History snapshot caches grow without bound** — `lush/NotesModel.swift:1732`, `:184`. Full attributed documents retained until app quit. Fix: small LRU (the capacity-12 session pattern) or clear on history-viewer close.
- [ ] **`releaseCore` is dead and incomplete** — `lush/NotesModel.swift:1101`. Fix: delete it, or complete it (nil `NativeWebStorage.shared.core`, detach semantic index, nil `delegateBridge`, resume `startupWaiters`).

## Phase 7 — SwiftUI render efficiency

- [ ] **Any preview/thumbnail/meta write re-renders every sidebar row** — `lush/ContentView.swift:1330`, `:1375`, `:1388`; writes at `NotesModel.swift:2310` (~8 Hz while typing) and `:1289` (cascade on scroll). Fix: per-note observable wrapper (or parent-computed values) so one key invalidates one row.
- [ ] **`node(for:)` full-tree scan per row per render** — `lush/NotesModel.swift:848` (callers `ContentView.swift:615`, `:1382`, sheets). Fix: `[String: FolderNode]` index maintained in `buildTree()`.
- [ ] **AgendaScreen re-groups + re-sorts everything on hover** — `lush/AgendaScreen.swift:103`. Fix: cache grouping keyed on `(items, horizon)`; move hover state into row subviews.
- [ ] **Pad card drag decodes JSON + rebuilds attributed string 2×/frame** — `lush/ScratchpadView.swift:778`. Fix: compute once per body / cache keyed on `item.data`.
- [ ] **Ink canvas re-outlines every stroke per pen sample** — `lush/ScratchpadView.swift:346`. Fix: live stroke in its own Canvas; cache stored strokes' Paths.
- [ ] **`PadStore.notePad` spawns an FFI task per call, no in-flight/negative cache** — `lush/Scratchpad.swift:65`. Fix: `loading`-set pattern + known-missing sentinel.
- [ ] **HtmlEditorSheet reloads WebKit per keystroke** — `lush/MediaViews.swift:858`. Fix: ~300 ms debounce.
- [ ] **Sidebar search: full FTS + semantic per keystroke, no debounce, detached work ignores cancellation** — `lush/ContentView.swift:478`, `:1590`; `NotesModel.swift:2159`. Fix: debounce 150–250 ms; pass a generation into the detached work so it bails early.
- [ ] **IncomingContentSheet walks the tree per keystroke** — `lush/ContentView.swift:4366`. Fix: compute `allNotes` once into `@State`, filter that.
- [ ] **Audio views poll at 10 Hz while idle** — `lush/MediaViews.swift:153`, `:691`. Fix: run the loop only while playing.

## Phase 8 — Web layer

- [ ] **Wasm boot: full downloads then 1.7 MB sync compile on main** — `web/src/main.ts:57` (repeated per embed via shellJS). Fix: hand the fetch `Response` to the async initializers so both compile streaming in parallel.
- [ ] **Connection-status interval polls wasm forever after the UI is removed** — `web/src/main.ts:99`. Fix: clear on `mountFrame`.
- [ ] **Settings overlay keydown listener leaks unless closed via Escape** — `web/src/settings.ts:125`. Fix: one close function removes overlay + listener.
- [ ] **SW caches all cross-origin (incl. opaque) responses, never pruned** — `web/public/sw.js:121`. Fix: capped external cache; stop caching opaque responses.

## Phase 9 — Consolidation (duplication)

Do these after the behavioral fixes above so there's one place to fix, not two.

- [x] **Embed shellJS ↔ `web/src`** — `lush/PatchworkView.swift:416` vs `resolver.ts`/`main.ts`; already drifted (IndexedDB cache, `localWsPort` vs `localWsPorts`). Fix: second Vite entry (`embed.ts`) importing the shared modules; WKWebView loads the built bundle instead of a Swift string literal.
- [x] **Share extension ↔ Finder action ↔ Shared handoff codec** — `LushShareExtension/ShareViewController.swift:50`, `LushFinderAction/FinderActionRequestHandler.swift:33`, `Shared/SharedIntake.swift:103`. ~150 lines duplicated; provider priority already differs; codec drift silently discards shared content. Fix: move loaders + codec into Shared/, compile into both targets, pick one priority order.
- [ ] **Intake drain + import: app vs helper, diverged behavior** — `lush/NotesModel.swift:2884` vs `LushHelper/HelperSync.swift:136`. Same share produces a rich note or a raw asset depending on which process drains. Fix: one implementation in Shared/ (incl. one UTType-based mime lookup).
- [ ] **`writeWidgetSnapshot` app vs helper** — `lush/NotesModel.swift:1173` vs `LushHelper/HelperSync.swift:246`. Fix: one builder in Shared/.
- [x] **Widget snapshot schema duplicated into the widget target** — `LushWidget/LushWidget.swift:62` vs `Shared/SharedIntake.swift:3`. Silent decode fallback on drift. Fix: compile the structs' file into LushWidgetExtension; delete the copies.
- [x] **HTML→spans converter ×2** — `lush/AppleNotesImporter.swift:90` vs `lush/RichTextClipboard.swift:276`; list-marker trimming already diverged. Fix: keep the clipboard version, merge the bullet-regex cases into `trimListMarker`, delete the importer's copy.
- [x] **Dock tile codec/filename/group id ×2** — `LushDockTile/LushDockTilePlugin.swift:75` vs `lush/NotesModel.swift:3225`. Fix: small Shared file in both targets.
- [x] **`NotesModel` re-declares LushShared constants (+ a third inline literal)** — `lush/NotesModel.swift:234`, `:2787`. Fix: use `LushShared.*`.
- [x] **ms-vs-s timestamp heuristic ×2** — `Shared/SmartNotebookRun.swift:118` vs `lush/NotesModel.swift:2774`. Fix: one shared helper (better: normalize in the core at write time).
- [x] **`account:` URL parsing Swift vs web, different rules** — `lush/NotesModel.swift:261` vs `web/src/account.ts:39`. Fix: adopt the stricter web rule in Swift.
- [x] **Sentence-embedding model loaded twice; normalization ×2** — `lush/SemanticSearchIndex.swift:75` vs `Shared/SmartNotebookRun.swift:127`. Fix: QueryEmbedding owns model + normalization; SemanticSearchIndex delegates.

## Suggested order of attack

1. Phase 1 items 1–3 (the three real data-loss paths: dropped ingest, unguarded panics, empty-snapshot overwrite) — smallest diffs, highest stakes.
2. Rest of Phase 1, then Phase 2 (mechanical, low-risk, pattern already established in-repo).
3. Phase 3 + the `refreshNotes` crawl item from Phase 6 — the two biggest felt-latency wins (typing in big notes, launch/search readiness).
4. Phases 4–5 together (same files, `core/src/repo.rs` + `api.rs`).
5. Phases 6–8 as time allows.
6. Phase 9 last, each consolidation its own commit.
