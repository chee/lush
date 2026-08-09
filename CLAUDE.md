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

## Architecture

- `NotesModel` — `@MainActor @Observable`, owns the Rust `Core`
- `AgendaStore` — `@MainActor @Observable`, owns `EKEventStore`
- Views get model access via `@Environment`

## Style

Follow the existing code — no comments, no ceremony, plain functions over classes where they fit.
