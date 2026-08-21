# Lush — HIG audit

An audit of the app against the Apple Human Interface Guidelines, 2026-08-21.
Universal app (macOS + iOS/iPadOS, deployment target 26.5), audited across
navigation, menus, controls, dialogs, foundations (color/type/accessibility),
interaction patterns, and system experiences. File references are to the
state of the repo at the time of the audit.

The short version: the bones are excellent — adaptive navigation, deep and
correct system integration (widgets, App Intents, Spotlight, Handoff,
Services, Focus), contextual permissions, good empty states, real menus with
real shortcuts. The problems cluster in four places: a macOS Quit override
that breaks a core platform contract, an error channel that no view renders,
one permanent delete that skips both confirmation and undo, and a large
amount of fixed-size type that defeats Dynamic Type on iOS.

---

## High

### 1. ⌘Q doesn't quit (macOS)

`lush/LushApp.swift:32` — `applicationShouldTerminate` answers
`.terminateCancel` for every user-initiated quit, hides the app, and flips it
to `.accessory` activation policy. Only logout/restart/shutdown actually
terminate. The one real "Quit" lives in the menu-bar extra
(`lush/MenuBarCaptureView.swift:165`).

Users own the Quit command. An app that wants to keep syncing in the
background should make that a visible choice ("Keep Lush running in the menu
bar" setting, on by default if you like), and Quit from the app menu should
do what it says — or at minimum the menu item should be renamed to describe
what it does. The `.accessory` flip also removes the app from the Dock and
⌘-Tab while it's still running, so the app appears to have quit while it
hasn't — the opposite of the transparency the HIG asks for. (HIG: Designing
for macOS; Menus — people expect standard menu items to behave predictably.)

### 2. The app's error channel is never displayed

`NotesModel.status` is where nearly every failure lands — "Couldn't
import…" (`lush/ContentView.swift:411`), "Couldn't remove note…"
(`lush/NotesModel.swift:823`), "Couldn't delete note…"
(`lush/NotesModel.swift:1970`), "Couldn't restore note…"
(`lush/NotesModel.swift:849`), plus instructional messages like "Copied to
clipboard — paste into the note" (`lush/ContentView.swift:5983`). No view
renders it. The only reader is the App Intents error path
(`lush/QuickActions.swift:377`). The two `Text(status)` sites in the app
(`lush/SettingsView.swift:120`, `lush/MenuBarCaptureView.swift:83`) show
local state, not this.

So: a delete that fails in the Rust core fails silently; an import error is
invisible; the "paste into the note" hint never reaches anyone. Every action
needs perceivable feedback, and failures most of all (HIG: Feedback). A
small dismissable status strip above the sidebar footer, or routing these
through user notifications when the window's away, would close the loop.
Undo registration compounds this: `removeEntry`'s undo is registered only
after success, which is right — but the user can't tell the difference
between the two outcomes.

### 3. "Delete Note" in the agenda is permanent, unconfirmed, and not undoable

`lush/AgendaScreen.swift:426` calls `model.deleteNote(noteUrl)` from a
context menu. `deleteNote` (`lush/NotesModel.swift:1964`) permanently
deletes the doc — no confirmation, no `registerUndo`, nothing recoverable.
Meanwhile the same word "Delete" everywhere else
(`lush/NoteContextMenu.swift:89`, folder screens, note toolbar) is an
undoable unlink via `removeEntry`.

The HIG's preferred shape is undo over confirmation — the unlink path
already does this well, with named undo actions. The agenda path needs one
of: route through the same undoable removal, a confirmation dialog, or both.
It also shouldn't share a label with the recoverable action; if it truly
destroys the note, say so ("Delete Permanently") and confirm. (HIG: Feedback
— "Ask for confirmation before performing a destructive action"; Undo and
redo.)

### 4. Dynamic Type is widely bypassed on iOS

The app has a genuinely good adaptive-type system — `uiFont(_:)` maps to
text styles, custom families go through `Font.custom(_:size:relativeTo:)`,
and nav bars use `UIFontMetrics` (`lush/InterfaceFont.swift`). But a large
share of the UI sidesteps it with fixed sizes:

- `lush/AgendaScreen.swift:252-383` — the date headers (34/30pt bold) and
  every event row (12-15pt)
- `lush/ContentView.swift` — sidebar badges, inspector text, presence and
  draft badges (9-12pt at ~15 sites)
- `lush/FormatPopover.swift`, `lush/MediaViews.swift`,
  `lush/Agenda.swift:770-790`, `lush/ContextTracker.swift:384`

None of these scale when a user raises their text size, and the agenda —
a primary screen — is the worst affected. Sweep these to `uiFont(...)` /
text styles, or wrap with `@ScaledMetric` where a fixed ratio matters
(HIG: Typography; Accessibility — "Support larger text sizes").

Related bug: `lush/InterfaceFont.swift:20` — when a size adjustment is set
for the *system* family, the path switches from `.system(style)` to
`.system(size:)`, which silently stops tracking Dynamic Type. `.system(size:)`
can take `relativeTo:` semantics via `Font.system(_:design:)` styles or
`@ScaledMetric`; as written, choosing a UI font scale kills scaling.

---

## Medium

### 5. No share sheet, no export on iOS, no printing

There is no `ShareLink`, `UIActivityViewController`, or
`NSSharingServicePicker` anywhere in the app. On iOS a note cannot leave the
app at all; on macOS the only exit is "Export as HTML…" in the note's More
menu. A notes app is exactly the kind of app where people expect the system
share sheet (send text to Messages, save PDF, AirDrop) and, on macOS,
File > Print (⌘P). The share sheet also gets you "Copy", "Save to Files",
and Shortcuts integration for free. (HIG: Collaboration and sharing;
Printing.)

### 6. VoiceOver gaps in the macOS format controls and agenda rows

- `lush/FormatPopover.swift:100-121` — the bold/italic/underline/strike
  buttons are `Text("B")`, `Text("I")`, etc. VoiceOver reads "B". No
  `accessibilityLabel`, and active state (accent tint only) carries no
  `.isSelected` trait. The iOS format panel does this correctly
  (`lush/RichTextEditor.swift:6030-6058` — labels, values, selected traits),
  so the pattern is already in the codebase; the macOS popover needs the
  same treatment.
- `lush/AgendaScreen.swift:416` — event rows are plain views with
  `.onTapGesture`, so VoiceOver doesn't expose them as activatable buttons.
  Wrap in `Button` (style `.plain`) or add
  `.accessibilityAddTraits(.isButton)` + `.accessibilityAction`.
- Overall coverage is thin: ~36 accessibility modifiers across ~53k lines,
  concentrated in the iOS editor bar. The custom sidebar (selection via
  `PrimaryClickGesture`, manual `.onKeyPress(.return)` handling,
  `lush/ContentView.swift:752,824`) reimplements List selection and is worth
  a VoiceOver + full-keyboard-access pass on macOS.

### 7. Touch targets under 44×44 pt on iOS

- Folder disclosure chevron: 24×32 pt (`lush/ContentView.swift:2562`)
- Search token pills: ~24 pt tall capsules (`lush/ContentView.swift:2337-2350`)

Padding out the `contentShape` costs nothing visually. (HIG: Layout;
Accessibility — "Offer sufficiently sized controls".)

### 8. No haptics on iOS

Zero uses of `sensoryFeedback` or the feedback generators. Reordering,
capture saved, recording start/stop, toggling Moon Mode — all silent.
Light impact/success haptics on capture and record transitions are cheap
wins. (HIG: Playing haptics.)

### 9. Motion: continuous menu-bar animation, no Reduce Motion anywhere

`lush/MenuBarCaptureView.swift:15` rotates the menu-bar icon continuously
while exports are in flight — persistent motion in a shared system area the
user can't dismiss. And there are no `accessibilityReduceMotion` checks in
the app (22 animation sites). The menu-bar spinner should be subtle or
static (badge/dot), and the handful of decorative animations should gate on
Reduce Motion. (HIG: Motion.)

### 10. Custom bottom search bar on iOS instead of `.searchable`

`lush/ContentView.swift:2761-2782` hand-builds the search field. The macOS
side uses `.searchable` with tokens, scopes, and suggestions — genuinely
sophisticated. The iOS side loses the system search affordances (activation
animation, Cancel button, integration with the OS 26 bottom-aligned toolbar
search treatment) and the token UX that exists on macOS. `.searchable` with
the toolbar placement gets the modern treatment for free and would let the
two platforms share the token/suggestion code.

### 11. System undo integration on iOS is partial

`NotesModel.undoManager` is a standalone manager. The toolbar Undo/Redo
buttons (`lush/ContentView.swift:2720-2732`, `4265-4285`) work, but system
undo gestures (three-finger swipe, shake) only reach the text editor's own
manager. Registering model undos with the window's `undoManager` (via
`@Environment(\.undoManager)` at the scene level) would unify them.

### 12. ⌘E shadows "Use Selection for Find"

`lush/LushApp.swift:319` binds ⌘E to Inline Code. On macOS, ⌘E is the
system-wide "Use Selection for Find" convention in text apps — and Lush has
a full find system (⌘F/⌘G/⇧⌘G all present and correct). Notion-style ⌘E for
code is a defensible product choice, but in a text-first macOS app the
convention leans the other way; consider ⌥⌘E or accept the tradeoff
knowingly. (HIG: Keyboards — don't repurpose standard shortcuts.)

---

## Low

### 13. Copy that will bite eventually

- `NSMicrophoneUsageDescription` ends with "hehe"
  (`Lush.xcodeproj/project.pbxproj:691`). Permission prompts are system UI;
  this is also an App Review risk.
- Two competing Focus usage strings: the polished one in `lush/Info.plist`
  and a terse fragment in build settings
  (`INFOPLIST_KEY_NSFocusStatusUsageDescription`, project.pbxproj:689) —
  resolve which one ships.
- Sync Diagnostics footer: "…this should happen automatically but i am not
  good at computer programming", "your friend codes still works. You'll
  still be logged out tho" (`lush/SettingsView.swift:346`). Personal-app
  charm — keep it if it's just for you, but it's out of register with the
  rest of the UI, which is well-written.
- "Saving..." / "Saving clipboard..." use three periods
  (`lush/MenuBarCaptureView.swift:278,292`); the rest of the app correctly
  uses "…".

### 14. SF Symbol choices

- `apple.logo` for the System settings tab (`lush/SettingsView.swift:36`) —
  the Apple logo is a restricted-use symbol reserved for referring to Apple
  itself (Sign in with Apple, etc.). A `gearshape.2` / `macwindow` style
  symbol is safer.
- `sparkles.tv` for Machine Learning (`lush/SettingsView.swift:33`) — that's
  a television. `sparkles` or `brain.head.profile` read closer.
- The Export menu uses `square.and.arrow.up` (`lush/ContentView.swift:4366`),
  which the system reserves for Share. If finding #5 adds a real share
  action, give Export a different glyph.
- Inspector toggle uses `info.circle` on macOS
  (`lush/ContentView.swift:4255`); the platform convention is a
  `sidebar.trailing`-style inspector glyph.

### 15. No swipe actions on iOS lists

Pin/delete/move are context-menu-only. Swipe actions are the conventional
fast path in list-driven apps (leading: pin; trailing: delete). `.onDelete`
alongside the existing `.onMove` in edit mode would also give Edit mode a
purpose beyond reorder.

### 16. iOS app icon has no dark/tinted variants

`AppIconIOS.appiconset` carries a single 1024 image. iOS 18+ renders
dark/tinted Home Screens by auto-generating variants unless you provide
them, and OS 26 favors the Icon Composer layered format for Liquid Glass.
Worth generating proper variants. (HIG: App icons.)

### 17. Assorted

- Settings window is fixed 620×620 (`lush/SettingsView.swift:40`); panes
  differ a lot in content height — per-pane sizing reads better on macOS.
- No localization scaffolding (no String Catalog). Fine for a personal app;
  a constraint on any future distribution.
- iPhone root toolbar is crowded (Settings, Moon Mode, Edit, Undo, Redo,
  New) — consider folding Undo/Redo into a menu or relying on gestures once
  #11 lands.
- The default `TextField("", …)` in the menu-bar capture panel has no
  prompt text (`lush/MenuBarCaptureView.swift:42`) — placeholder text like
  "Capture a thought…" helps both discoverability and VoiceOver.

---

## What's already right (keep it)

- **Navigation**: `NavigationSplitView` on macOS and wide iPad,
  `NavigationStack` on iPhone, `ContentUnavailableView` for empty detail and
  empty agenda — textbook adaptive structure.
- **Permissions**: every usage description present; requests are contextual
  (calendar access is asked when the agenda opens, with a proper
  `ContentUnavailableView` explainer and an Allow Access button —
  `lush/AgendaScreen.swift:26-35`); a Permissions settings pane with
  per-kind state and System Settings deep links.
- **Destructive-flow gold standard**: the Clear Local Storage flow
  (`lush/SettingsView.swift:325-342`) — destructive role, visible title,
  explicit consequences, distinct "Keep Identity" escape hatch.
- **Menus**: full menu bar with Format/Find/View commands, standard
  shortcuts (⌥⇧⌘V Paste and Match Style), New menu with ⌘N/⇧⌘N, dock menu
  with recents, Services integration.
- **Search on macOS**: `.searchable` with tokens, editable pills, scopes,
  suggestions, ⌘F/⇧⌘F focus commands. (Bring this to iOS — see #10.)
- **System experiences**: configurable folder widget with per-family
  layouts, lock-screen accessory widgets, Control Center controls, App
  Shortcuts, Spotlight indexing + restoration, Handoff, background sync
  tasks, share/Finder/dock-tile extensions.
- **Dark mode**: custom colors are consistently paired light/dark
  (`SpanDoc`, `ListMarkerLayoutFragment`, `CodeHighlight`, menu-bar panel).
- **Modern presentation**: detents + drag indicator + background
  interaction on the iOS inspector, `glassEffect` on the format island,
  `interactiveDismissDisabled` only while drawing.
- **Feedback plumbing**: progress indicators are used liberally and sized
  properly; undoable removals set named undo actions ("Remove Note").

## Suggested order of attack

1. Render `NotesModel.status` somewhere (or convert it to a toast/notice
   queue) — #2 unlocks trust in everything else.
2. Fix the agenda delete (#3) — small change, removes the one data-loss
   trap.
3. Decide the Quit story (#1) — setting + honest menu item.
4. Dynamic Type sweep (#4) — mechanical, biggest accessibility payoff.
5. `ShareLink` on the note More menu + macOS Print (#5).
6. macOS format popover a11y labels/traits (#6) — copy the iOS panel's
   pattern.
7. The rest as they annoy you.
