# Apple Integrations Plan

## Done

- Handoff for open notes and folders.
- Spotlight indexing for notes.
- Lock Screen widgets for Quick Note and New Note.
- Control Center controls for Quick Note and New Note.

## Next Priorities

### 1. Drag-In Import Choice

When a person drops content into a note or folder, ask what Lush should do with it instead of guessing.

- For files:
  - Keep as File attachment.
  - Import into Rich Note when the file type can be converted.
  - Link only for files that should remain external.
- For folders:
  - Import folder as notes.
  - Attach folder archive or reference.
- For URLs:
  - Save as link.
  - Archive page as note when page capture is available.
- For Automerge files:
  - Load `.amrg` / `.automerge` bytes with `Automerge.load(bytes)`.
  - Offer to import the Automerge document into the current folder.

Implementation notes:
- Reuse `IncomingContent` as the staging model if possible.
- Add an `ImportDecisionSheet` used by drag/drop, share extension, Finder actions, and Safari capture.
- Keep the editor drop target fast: load metadata first, then let the sheet perform heavier reads/imports.

### 2. Quick Look for `.amrg` / `.automerge`

Add a Quick Look preview extension for raw Automerge-save files.

- Read bytes from the selected file.
- Decode with `Automerge.load(bytes)`.
- Show stable metadata:
  - document type/datatype
  - title if present
  - heads count or saved timestamp when available
  - readable rich-note preview for known Lush note docs
- Avoid editing or syncing from Quick Look.

Implementation notes:
- Start with a plain SwiftUI preview view.
- Prefer a graceful “Unknown Automerge document” view over throwing for unsupported document shapes.
- Register UTTypes for `.amrg` and `.automerge`.

### 3. Safari Extension: Archive Page as Note

Bring over the useful parts from `~/soft/chee/patchwork-playground/aftersun` and make the Safari extension do one thing well: archive the current page as a Lush note.

- Capture:
  - page title
  - canonical URL
  - selected text when present
  - readable article content
  - capture timestamp
- Save behavior:
  - default to Quick Note or Inbox
  - optionally create a new note for the page
  - include source URL prominently at the top

Implementation notes:
- Keep this separate from the generic share extension.
- Do not build a broad bookmark manager UI in the extension.
- Make the capture result a normal rich note, not a special browser-only object.

### 4. Finder Actions

Make Finder integration useful for files and folders.

- Add to Lush.
- Attach to Quick Note.
- Import as Rich Note.
- Import Folder as Notes.
- Copy Lush URL for Lush-managed items when detectable.

Implementation notes:
- Finder actions should hand off selected file URLs through the same import decision path as drag/drop.
- Avoid doing long imports inside the Finder extension process; stage and open Lush when needed.

### 5. App Shortcuts Expansion

Add shortcut actions that map to real daily capture flows.

- Append to Quick Note.
- Search Lush.
- Open Recent Note.
- Create Note from Clipboard.
- Record Audio Note.
- Capture URL.

Implementation notes:
- Keep actions parameterized by `LushFolderEntity` where a destination matters.
- Prefer actions that can complete in the background for append/import flows.
- Use `openAppWhenRun = true` only when the action needs an editor or confirmation.

### 6. Focus Filters

Let Focus modes change Lush behavior.

- Choose default capture destination.
- Choose visible folder set.
- Override Quick Note.
- Enable or disable context capture.

Implementation notes:
- Start with a simple focus-filter model in `UserDefaults` or app group defaults.
- Apply filters in `NotesModel.folderTree`, Quick Capture, widgets/controls, and shortcuts.
- Make “no filter” the default behavior.

### 7. Live Activity

Use Live Activities for long-running iPhone tasks.

- Recording note.
- Transcribing audio.
- Importing a large file/folder.
- Possibly sync/export later.

Implementation notes:
- Start with recording/transcription because those are user-visible and time-bound.
- Include pause/stop/open-note actions only if the backing state is reliable.
- Keep displayed content non-sensitive on the Lock Screen.

### 8. Menu Bar Redesign

Replace the current Mac menu bar item with a small, warm quick-capture surface.

Visual direction:
- Cute, pretty, pink/peach/cream.
- Soft but still Mac-native.
- Compact enough to feel like a menu bar utility, not a separate app window.

Actions:
- New Note.
- Append Clipboard to Quick Note.
- Record Audio.
- Search.
- Open Lush.

Implementation notes:
- Keep `MenuBarExtra` with `.window` style.
- Use a dedicated `MenuBarCaptureView` rather than overloading `QuickCaptureView`.
- Make keyboard flow good: text field focused on open, Return captures, Escape dismisses.

## Suggested Order

1. Drag-In Import Choice.
2. App Shortcuts Expansion.
3. Safari Archive Page Extension.
4. Focus Filters.
5. Live Activity.
6. Menu Bar Redesign.
7. Finder Actions.
8. Quick Look for `.amrg` / `.automerge`.

This order keeps the app’s capture loop improving first, then adds deeper OS surfaces once the import/capture path is shared and reliable.
