# Lush — sync & sedimentree audit

An audit of the Automerge/sedimentree storage and sync layer, 2026-08-21,
against `@automerge/automerge-repo@2.6.0-subduction.48` as the reference
implementation (`src/subduction/source.ts`, `storage.ts`). Scope: the write
path (`ingest`), compaction, the load/open path, sync, memory behavior,
crash consistency, and the shape of the machinery itself. Everything below
was verified by reading the code directly; the machine-written comments were
treated as claims, not evidence — a couple of them turned out to be wrong,
and those are flagged where they matter.

**The CLAUDE.md invariants all hold in `ingest`** (repo.rs:872): fragment
levels are mirrored, never hand-built (tested by
`ingest_mirrors_automerge_fragment_levels`); filtering against
`stored_commits`/`stored_fragments` precedes bundling (tested by
`ingest_skips_records_already_stored`); the walk is `fragments(0..)`, never
level-0-only. The findings live in the machinery *around* ingest.

Also worth saying up front: the **outbox log is better than the reference**.
automerge-repo's durability window is its 100 ms save throttle; Lush's
keystroke path fsyncs an incremental log before returning
(`stage_doc`, repo.rs:1201), and eviction demands proof
(`staged_heads`) that disk can reproduce the doc's exact heads. The test
and fuzz coverage over ingest, the outbox, and eviction is genuinely strong.

---

## Data safety

### S1 — `reclaim_doc` can delete a just-persisted inbound commit · HIGH · **FIXED**

*Fixed 2026-08-21:* `reclaim_doc` now computes `absorbed = stored_commits −
live` under the state lock — a record persisted but not yet applied isn't in
`stored_commits`, so it can't be a candidate — and prunes the set only for
deletes that actually succeeded (failed deletes retry next pass, matching
the reference). The repro below is un-ignored and passing, and a new
positive test (`reclaim_drops_absorbed_commits_and_keeps_the_doc_rebuildable`)
proves absorbed commits still get dropped and the doc still rebuilds.
Original finding kept for the record:

`reclaim_doc` (repo.rs:1843) snapshots the live set from the in-memory doc,
**drops the state lock**, then enumerates loose commits *on disk*
(1872) and deletes everything not in the snapshot (1889). Inbound sync
records hit disk before their in-memory apply: `ObservedStorage` writes to
`FsStorage`, then queues the record on the stored-batch channel
(observed_storage.rs:85-99), and the serial apply loop (repo.rs:1740) gets
to it later. A record persisted between the snapshot and the delete pass is
on disk, absent from `live` — deleted.

The kicker is what happens next. The channel copy still applies to the
resident doc, and `apply_batch_to_state` adds its head to `stored_commits`
(1017), so every future `ingest` **skips re-storing it**: the change now
exists in RAM and on the remote, but on no local disk. Restart offline and
it's gone from the doc until a network round-trip heals it — and in a
peer-only topology (iroh, muted server) where the originating peer is gone,
it's gone for good. The window is small but the code runs on *every*
fragment-writing save (2444) and every inbound fragment batch (2362).
The doc comment on `reclaim_loose_commits` says dropping is "provably
safe" — the proof has this hole in it.

The reference is immune by construction: it computes stale sets
synchronously over in-memory hash sets in one JS tick (source.ts:1800-1818).
Lush already owns the equivalent sets — `stored_commits` is maintained as an
exact mirror of disk for a hydrated doc. **Fix direction:** compute
`absorbed = stored_commits − live` under the state lock and delete exactly
those heads, never re-enumerating disk; keep the disk-enumerating variant
only for the manual Settings pass over non-resident trees. That deletes the
race and a disk scan in one move.

**Demonstrated, not just read:**
`reclaim_spares_a_commit_persisted_but_not_yet_applied` (repo.rs, `#[ignore]`d)
constructs the persisted-but-not-yet-applied state deterministically and
fails today at `assert_eq!(dropped, 0)` — reclaim deletes the peer's commit.
Un-ignore it when the fix lands.

### S2 — one corrupt outbox chunk voids the whole log, which is then overwritten · MEDIUM · **FIXED**

*Fixed 2026-08-21:* when the whole-file replay fails, `open_local` now
renames the log to `.automerge.corrupt` before anything can overwrite it,
then salvages the chunks that still parse (`salvage_outbox`, splitting on
automerge's chunk magic) and persists whatever applied. Further empirical
refinement while fixing: automerge's own replay already tolerates
corruption *past* the first chunk (applies the prefix, drops the
unreachable tail), so the fatal shape was first-chunk corruption — its
content is beyond recovery by anything, but the log now survives for
forensics instead of being destroyed. Three tests cover the shapes:
`a_torn_outbox_append_keeps_the_flushed_prefix`,
`corruption_after_the_first_chunk_keeps_the_prefix`, and
`a_corrupt_outbox_chunk_preserves_the_log`. Original finding:

- **The crash shape is safe.** A torn tail — an append that died mid-write —
  replays its fsync'd prefix fine. Verified by a new (live) regression test,
  `a_torn_outbox_append_keeps_the_flushed_prefix`. Trailing garbage is also
  tolerated. Credit where due: this is the common power-loss case, and it
  works.
- **Content corruption is not.** Flip one byte *inside* a chunk (partial
  page write during power loss, or bit rot) and `merge_outbox_into` (1161)
  fails for the entire file — including intact chunks *after* the corrupt
  one. `open_local` logs "staged doc failed to replay" and carries on
  (2832-2838) with `staged_heads = None`, so the next keystroke's
  `stage_doc` **replaces the file** with a fresh full save (1227-1233) —
  the abandoned log, the only copy of those keystrokes, is gone.
  Demonstrated by `a_corrupt_outbox_chunk_keeps_the_other_chunks`
  (`#[ignore]`d, fails today).

**Fix direction:** on replay failure, rename the log aside
(`.automerge.corrupt`) before anything can overwrite it, and salvage the
chunks that do parse. Never let the "replay failed" path and the "safe to
rewrite" path share a state.

### S3 — metadata edits have no outbox · MEDIUM

`change_doc` / `change_doc_at` (2624, 2646) — folder operations, renames,
`update_note_spans` — mutate in memory and then `save_doc`. On save failure
the caller gets an error (and since today's UI change, the user actually
sees it), but the mutation lives only in RAM; a kill before the next
successful save loses it. The keystroke path solved exactly this with the
outbox. Either route these through `stage_doc` too, or decide explicitly
that metadata edits are acceptable to lose and write that down.

### S4 — the `failed` digest quarantine defeats its own repair · MEDIUM

A blob that fails to load once goes into `state.failed` (1070) and is then
filtered out of **every** future batch (1034, 1042) for as long as the doc
stays resident. The "local storage incomplete; requesting repair" event
fires, the repair sync re-delivers the same blob — whose digest is in
`failed` — and it's filtered before load. The doc is stuck until eviction
rebuilds state from disk, and a pinned/open doc (the note being edited)
never evicts. Clear `failed` entries when their blob is re-received, or
when a repair round begins.

### S5 — a deterministic `fragments()` panic routes a doc to the outbox forever · MEDIUM-LOW

`ingest` returning `None` (upstream automerge panic, repo.rs:869-878)
stages to the outbox and retries next save (2406-2411). If the panic is
deterministic for a doc's change graph, that doc silently stops syncing
outward and its log grows with every keystroke, forever — the only trace is
a `tracing::warn`. Surface it (a `RepoEvent` after N consecutive failures)
and bound the log by periodically rewriting it compacted.

### S6 — two storage instances over one sedimentree directory · MEDIUM-LOW (design)

The in-process Patchwork relay opens its **own** `FsStorage` and Subduction
node on the same `data_dir/sedimentree` the repo uses
(server-rs/lib.rs:181, "one copy, not two"). Three consequences worth
deciding about, not discovering: server writes bypass `ObservedStorage`, so
resident docs don't see them until some sync path re-reads; the two
`ids_cache`s can diverge; and the repo's reclaim can delete loose commits
the server's in-memory sedimentree still indexes, so the server may
advertise records it can no longer load. CAS tmp-nonce + rename semantics
make the concurrent writes themselves safe.

---

## Correctness and robustness

### C1 — no save single-flight, no heads fast path · MEDIUM

The reference holds `saveInProgress` and skips when heads equal
`lastSavedHeads` (source.ts:1407-1431). Lush has neither: `save_doc` aborts
the debounced task and immediately runs its own `save_doc_now` while the
aborted task may be mid-`store_built_batch` (2371-2376) — eviction, drains,
and mute-toggles add more concurrent entry points. Nothing corrupts (CAS
dedupes, ingest is idempotent) but two ingests of the same commits can run
concurrently, and every debounce tick pays a full `fragments(0..)` walk even
when nothing changed. A per-doc save slot (the `SyncSlot` pattern already in
the file) plus a heads-equality skip removes a whole class of reasoning.

### C2 — evict/write race orphans an edit · MEDIUM-LOW

`change_doc` clones the doc's `Arc` out of the map, releases the map lock,
then locks the state (2628-2634). `evict_doc`'s final phase can win in
between: map lock + successful `try_lock` + heads check + remove
(2929-2942). The writer then mutates an orphaned `DocState`; the follow-up
`save_doc` fails with unknown-doc and the caller gets an error — but the
edit is gone. Narrow, and it lands exactly on the "wake up and type into an
idle note" moment. After locking the state, re-verify the map still holds
this same `Arc` before mutating.

### C3 — stage failure skips the ingest schedule · LOW

`change_doc_at_deferred_ingest` (2714): if `stage_doc` fails, the error
returns before `schedule_save_doc` — the mutation is in the doc but no save
is scheduled. Schedule it anyway; the outbox failed, the sedimentree path
is the fallback.

---

## Memory and disk growth

### M1 — superseded fragments are never deleted · MEDIUM · **FIXED**

*Fixed 2026-08-21:* `reclaim_doc` now diffs `stored_fragments` against the
live view under the same lock as the commit diff and deletes fragments the
doc no longer reports; a reclaim pass also runs at the end of `open_local`,
so long-dormant docs shed accumulated cruft the first time they're read.
Empirical note from building the test: folding is a scale phenomenon —
levels are content-hash-derived and a level-2 fragment needs on the order
of 65k changes, at which point the covered level-1 fragments leave the
reported view. `reclaim_drops_fragments_a_bigger_fragment_replaced` drives
a doc past that point and verifies the superseded records leave the disk
while the doc rebuilds identically. The Settings action is now honestly
named "Reclaim Absorbed Records". Original finding:

`reclaim_doc` deletes loose commits only; `delete_fragment` has no caller in
repo.rs. Every fragment automerge ever forms — including every level-n
fragment later folded into a level-(n+1) — stays on disk forever, meta +
full bundle blob. The reference deletes stale fragments in the same pass as
stale commits (source.ts:1813-1848). Extend reclaim to fragments with the
same live-set logic — after S1's fix, since fragment deletion through a racy
reclaim would raise the stakes.

### M2 — per-doc sets grow without bound during residency · MEDIUM-LOW · **MOSTLY FIXED**

*Update:* `stored_fragments` and `stored_commits` are both pruned by
reclaim now. `applied`/`failed` still grow for the residency (cleared by
eviction), which is the remaining sliver of this finding.

`stored_fragments` never shrinks (the post-reclaim `retain` at 1910 touches
only `stored_commits`); `applied`/`failed` accumulate a digest for every
record ever seen and are cleared only by eviction. Fine for notes; long
sessions on pinned, high-churn docs pay it. M1's fix naturally prunes
`stored_fragments`.

### M3 — every local save echoes back through the apply loop · LOW-MEDIUM · **FIXED**

*Fixed 2026-08-21:* `save_doc_now` pre-marks the stored blobs' digests in
`state.applied` in the same lock that extends the stored sets, so the echo
filters to nothing; and the on-receive reclaim now runs only when a batch
actually advanced the doc, which drops the second reclaim per
fragment-writing save. `saved_blobs_are_marked_applied_before_the_echo`
pins the mechanism. Original finding:

`store_built_batch` writes through `ObservedStorage`, which clones each
record into the channel unconditionally — including the doc's own saves.
The apply loop then `load_incremental`s the doc's own bytes back into it
(the digests aren't in `applied`; only the apply path populates it), and a
fragment-writing save runs `reclaim_doc` **twice** (2444 and 2362). The
reference dedupes this exact echo with `knownHashes` (source.ts:640-651).
The fix reuses existing machinery: after a successful `store_built_batch`,
insert the new blobs' digests into `state.applied` in the same lock that
extends the stored sets (2433-2437) — the echo then filters to nothing.

### M4 — one doc's apply cost backpressures every doc's writes · LOW (deliberate)

The stored-batch loop is serial and `ObservedStorage` awaits the channel
send (queue depth 64). A slow apply on one large doc stalls disk-write
acknowledgement for all inbound sync. Chosen on purpose (repo.rs:95-98) —
worth remembering when a multi-doc burst lands behind a big asset apply.

---

## Performance

### P1 — full-tree disk reads on hot paths · HIGH (perf) · **FIXED (hot paths)**

*Fixed 2026-08-21:* `apply_missing_blobs` diffs record heads (cheap
metadata enumeration) against the in-memory stored sets and loads only the
blobs those sets don't know — in steady state, none, since the
stored-batch channel already delivered everything a sync wrote. `sync_once`
and `on_remote_heads` now use it; the full-tree read remains only where it
belongs: the open path, the apply-error recovery path, and the
`pending_change_count` diagnostic. Original finding:

Four paths re-read **every blob of a doc** from disk:

- `sync_once` after any data-bearing round (2159 → `apply_new_blobs` →
  `stored_batch` = `load_loose_commits` + `load_fragments`)
- `on_remote_heads` for a tracked doc with missing deps (2130) — during a
  collaborator's typing burst this runs per announcement
- the apply-error recovery path (1754)
- `pending_change_count` (1322) — materializes a whole second Automerge doc
  to answer a diagnostic count

The blobs are then digest-filtered so the *parse* is cheap, but the I/O is
O(doc-on-disk) each time. The reference does its full `getBlobs` read once,
at the initializing transition; steady-state applies are per-record events.
Lush already has the per-record channel — the steady-state paths could trust
it (await channel settle instead of re-reading), or read metas first and
load only blobs whose heads are missing from the stored sets.

### P2 — heal policy: flat 5 s × 12, per doc, three mechanisms · MEDIUM

`request_sync_inner`'s inline loop retries every 5 s up to 12 times
(2259-2281); `ensure_doc` and `track_doc` each spawn their *own* retry
loops. N unreachable docs → N loops, no exponential backoff, no jitter, no
exhaustion signal beyond per-failure SyncEvents. The reference funnels all
healing through one scheduler with 2 s → 60 s backoff and an
`onHealExhausted` callback. One scheduler here would cut code and radio
wakeups at once.

### P3 — small ones · LOW

`apply_batch_to_state` digests every blob twice (1033/1041 and again in
`concat_blob_batch`); the history cache evicts an arbitrary entry
(api.rs:688); `outbox_locks` never shrinks (tiny); `Core::shutdown` blocks
the calling thread by design.

---

## Feedback

### F1 — persistent save failures are invisible · MEDIUM

A failing debounced save is a `tracing::warn` (2462), as is a failing
drain (3074). The outbox keeps the bytes safe locally, but nothing tells
the user that persistence/sync has been failing for an hour. The Swift side
just gained a status surface — a `RepoEvent::SaveFailed(doc)` after
repeated failures would complete the loop the reference closes with
`lastSaveError` + rejecting `flush()`.

---

## Shape (simplicity, reuse, surface area)

1. **One save gate** (C1) — a per-doc slot + heads fast path removes
   concurrent-save reasoning and the wasted walks.
2. **One reclaim source of truth** (S1) — diffing in-memory sets replaces a
   disk enumeration and deletes the race; the disk-scanning variant remains
   only for the manual whole-store pass.
3. **One dedupe set** (M3) — populating `applied` on save makes the echo,
   the double-reclaim, and the redundant self-parse all disappear.
4. **One retry scheduler** (P2) — three ad-hoc retry loops become one.
5. **Comment hygiene** — the "provably safe" claim on reclaim (1836-1838) is
   falsified by S1; `let _ = sid;` at 2363 is dead; the Settings footer's
   "this should happen automatically but i am not good at computer
   programming" undersells code that *does* run reclaim automatically —
   and the footer outlived the facts. Comments that assert safety
   properties should cite the mechanism that enforces them.

## Addendum: the content pipeline (2026-08-22)

The indexer is now the single extraction stage the consumers feed from,
per the author's design:

- `search::indexed_doc` extracts everything once — leveled-up `body`
  (text + calendar-event lines + HTML embeds, which FTS was silently
  missing before), a `context` column carrying the logline enrichment the
  semantic index used to compute privately, the first calendar event's
  window, and the doc's EventKit ids — into new `search_docs` columns.
- `upsert` reports no-ops; a real write emits `RepoEvent::DocIndexed`,
  surfaced to Swift as `onDocIndexed`.
- `Core::note_content(url)` returns the row (`IndexedNoteContent`); the
  Spotlight and semantic indexers now react to `onDocIndexed`, read the
  row, and never open a doc. Their private extractors (and the
  `CalendarLinks` scan stapled to the semantic pass) are gone — the row
  carries `event_ids`.
- `Repo::read_stored` reads a doc without making it resident (resident →
  in place; else sedimentree + outbox replay, then dropped). `index_doc`
  and `note_preview` use it, so content consumption no longer touches
  residency at all — the precondition for shrinking the resident cache to
  "the last doc or two".

Upgrade behavior: the extended no-op comparison backfills every row once
(old rows lack the new columns), which fires `DocIndexed` across the store
and — with the embedding digest bumped to v3 — re-embeds each note once.

## Suggested order

1. ~~S1 (reclaim race)~~ — **done**.
2. ~~S2 (outbox salvage)~~ — **done**.
3. ~~P1 (stop full-tree reads in steady state)~~ — **done**.
4. ~~M3 (echo suppression)~~ — **done**.
5. ~~M1/M2 (fragment GC + set pruning)~~ — **done**.
6. C1 (save single-flight + fast path).
7. S4, F1, and the rest as they annoy you.

## Test results

After the S1/S2/P1/M1/M2/M3 fixes, `cargo test --release --lib` on this
container (Linux host, same crate): **100 passed, 0 failed, 6 ignored**
(the benches), stable across repeated runs.

Tests added by the audit and fixes:

- `reclaim_spares_a_commit_persisted_but_not_yet_applied` — the S1 repro,
  now live and passing.
- `reclaim_drops_absorbed_commits_and_keeps_the_doc_rebuildable` — the
  positive path: absorbed commits leave the disk, live tail stays, the doc
  rebuilds byte-identical.
- `a_torn_outbox_append_keeps_the_flushed_prefix` — torn-append crash
  shape replays its fsync'd prefix.
- `corruption_after_the_first_chunk_keeps_the_prefix` — mid-log corruption
  keeps the intact prefix.
- `a_corrupt_outbox_chunk_preserves_the_log` — first-chunk corruption
  moves the log aside and later stages leave it untouched.
