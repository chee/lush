---
name: lush-docs
description: Read, search, create, replace, and open documents in a running Lush app through its authenticated local API. Use when the user asks an agent to inspect or change her Lush notes, find material stored in Lush, create a Lush document, or open a known Lush document in the app.
---

# Lush Docs

Use `python3 scripts/lush_docs.py` for document operations. It discovers the running app through `agent.json` — the sandboxed app writes it to `~/Library/Containers/party.chee.patchwork.lush/Data/Library/Application Support/Lush/agent.json` (falling back to `~/Library/Application Support/Lush/agent.json`) — and never prints the bearer token.

## Find and read

- `python3 scripts/lush_docs.py status`
- `python3 scripts/lush_docs.py list`
- `python3 scripts/lush_docs.py search "query"`
- `python3 scripts/lush_docs.py folder "automerge:..."`
- `python3 scripts/lush_docs.py read "automerge:..."`

Search before reading when the document URL is unknown. Use the returned exact URL for subsequent operations.

## Create and edit

- `python3 scripts/lush_docs.py create --title "Title" --text "Body"`
- `python3 scripts/lush_docs.py create --folder "automerge:..." --title "Title" --file draft.txt`
- `python3 scripts/lush_docs.py write "automerge:..." --file revised.txt`
- `python3 scripts/lush_docs.py write "automerge:..." --title "New title" --text "Replacement body"`

`write` replaces the note body. Read immediately before writing and pass `--heads` with the comma-separated heads from that read when concurrent edits are possible. Preserve rich content by using the raw API and returning the `spans` array from the read with only the intended changes.

## Open in Lush

Use `python3 scripts/lush_docs.py open "automerge:..."` after an operation when the user asks to see the document in the app.

Read [references/api.md](references/api.md) when the script does not cover the required operation or rich spans must be preserved.
