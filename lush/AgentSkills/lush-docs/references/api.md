# Lush agent API

The running macOS app writes `agent.json` with `url`, `token`, and `protocol`. When sandboxed it lands in `~/Library/Containers/party.chee.patchwork.lush/Data/Library/Application Support/Lush/agent.json`, otherwise `~/Library/Application Support/Lush/agent.json`. Send `Authorization: Bearer <token>` on every request. Treat the file and token as private.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/status` | Protocol, root folders, selected note |
| `GET` | `/v1/notes` | 100 recent notes |
| `GET` | `/v1/notes?query=...` | Full-text search |
| `GET` | `/v1/folder?url=...` | Folder entries |
| `GET` | `/v1/note?url=...` | Title, plain text, spans, and Automerge heads |
| `POST` | `/v1/notes` | Create a note |
| `PUT` | `/v1/note?url=...` | Replace a note body |

## Create body

```json
{
  "folder_url": "automerge:...",
  "title": "Title",
  "text": "Body"
}
```

`folder_url` and `text` are optional. `spans` may replace `text` for rich content.

## Update body

```json
{
  "title": "Optional replacement title",
  "text": "Replacement body",
  "heads": ["optional-automerge-head"]
}
```

`spans` may replace `text`. Passing the heads returned by `GET /v1/note` makes stale concurrent edits fail instead of silently replacing newer content.

## Span shape

```json
[
  {"type": "block", "value": {"type": "paragraph", "parents": []}},
  {"type": "text", "value": "Text", "marks": {"strong": true}}
]
```

Return the original block and mark data when preserving rich content.

## Inter-app URLs

- `lush://show?doc=<automerge-url>` opens a document.
- `lush://search?q=<query>` opens search.
- `lush://new` creates a note.
- `lush://insert?text=<text>` inserts text into the active note.
