use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use automerge::{
    hydrate,
    iter::Span,
    marks::{ExpandMark, Mark, MarkSet, UpdateSpansConfig},
    transaction::{CommitOptions, Transactable},
    Automerge, ObjType, ReadDoc, ScalarValue, ROOT,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value as Json};
use unicode_segmentation::UnicodeSegmentation;

pub const RICH_TOOL_URL: &str = "automerge:2XoPZihn6Vo2aqeVu2WN39W8cdAN";

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum SpanJson {
    Block {
        value: Json,
    },
    Text {
        value: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        marks: Option<serde_json::Map<String, Json>>,
    },
}

fn tx<O>(r: automerge::transaction::Result<O, automerge::AutomergeError>) -> anyhow::Result<O> {
    r.map(|s| s.result).map_err(|f| anyhow::Error::new(f.error))
}

fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

/// Write a string field as a collaborative Text object — the representation
/// JS tools produce for plain string assignments. A scalar str would show up
/// in Patchwork as an ImmutableString.
fn put_text<T: Transactable>(
    t: &mut T,
    obj: &automerge::ObjId,
    key: &str,
    value: &str,
) -> Result<(), automerge::AutomergeError> {
    let id = t.put_object(obj, key, ObjType::Text)?;
    if !value.is_empty() {
        t.splice_text(&id, 0, 0, value)?;
    }
    Ok(())
}

/// Update a string field, diffing into an existing Text object when present.
fn set_text<T: Transactable>(
    t: &mut T,
    obj: &automerge::ObjId,
    key: &str,
    value: &str,
) -> Result<(), automerge::AutomergeError> {
    match t.get(obj, key)? {
        Some((automerge::Value::Object(ObjType::Text), id)) => t.update_text(&id, value),
        _ => put_text(t, obj, key, value),
    }
}

/// Replace an identifier field outright. `set_text`'s character diff is for
/// prose, where merging two edits keeps both; two devices diffing different
/// urls into the same field merges the spellings into a url neither wrote.
/// A fresh put makes concurrent writes a conflict automerge picks one whole
/// winner from.
fn set_identifier<T: Transactable>(
    t: &mut T,
    obj: &automerge::ObjId,
    key: &str,
    value: &str,
) -> Result<(), automerge::AutomergeError> {
    let current = match t.get(obj, key)? {
        Some((automerge::Value::Object(ObjType::Text), id)) => t.text(&id).ok(),
        Some((automerge::Value::Scalar(s), _)) => s.to_str().map(str::to_string),
        _ => None,
    };
    if current.as_deref() == Some(value) {
        return Ok(());
    }
    put_text(t, obj, key, value)
}

/// Whether a url is worth keeping when read back: an `automerge:` url that
/// doesn't decode is a casualty of the text merge `set_identifier` exists to
/// prevent, and handing it on just moves the error somewhere harder to see.
fn usable_url(url: &str) -> bool {
    !url.starts_with("automerge:") || crate::repo::DocId::from_url(url).is_ok()
}

/// Read a string field regardless of representation (Text object or scalar).
fn string_at(doc: &Automerge, obj: &automerge::ObjId, key: &str) -> Option<String> {
    let (v, id) = doc.get(obj, key).ok().flatten()?;
    match v {
        automerge::Value::Object(ObjType::Text) => doc.text(&id).ok(),
        automerge::Value::Scalar(s) => s.to_str().map(|x| x.to_string()),
        _ => None,
    }
}

fn fix_scalar_string<T: Transactable>(
    t: &mut T,
    obj: &automerge::ObjId,
    key: &str,
) -> Result<(), automerge::AutomergeError> {
    if let Some((automerge::Value::Scalar(s), _)) = t.get(obj, key)? {
        if let Some(v) = s.to_str().map(|x| x.to_string()) {
            put_text(t, obj, key, &v)?;
        }
    }
    Ok(())
}

/// Rewrite scalar-string fields as Text objects on docs this app created
/// before the representation was fixed. Idempotent; a no-op transaction
/// records no change.
pub fn normalize_strings(doc: &mut Automerge) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            fix_scalar_string(t, &ROOT, "title")?;
            if let Some((_, pw)) = t.get(ROOT, "@patchwork")? {
                fix_scalar_string(t, &pw, "type")?;
                fix_scalar_string(t, &pw, "title")?;
                fix_scalar_string(t, &pw, "suggestedImportUrl")?;
            }
            if let Some((_, docs)) = t.get(ROOT, "docs")? {
                for i in 0..t.length(&docs) {
                    if let Some((_, entry)) = t.get(&docs, i)? {
                        fix_scalar_string(t, &entry, "name")?;
                        fix_scalar_string(t, &entry, "type")?;
                        fix_scalar_string(t, &entry, "url")?;
                    }
                }
            }
            Ok(())
        },
    ))?;
    Ok(())
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct DocLink {
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub url: String,
    pub lush: Option<String>,
}

/// Scalar types JSON can't represent faithfully are wrapped in a tagged object
/// so the read → JSON → write round-trip preserves them. Without this, saving a
/// note rewrites other peers' block attrs (Bytes, Timestamp, Counter, wide
/// Uint) as the wrong scalar type. Str/Int/F64/Bool/Null stay bare JSON.
fn scalar_to_json(s: &ScalarValue) -> Json {
    match s {
        ScalarValue::Str(v) => json!(v.as_str()),
        ScalarValue::Int(v) => json!(v),
        ScalarValue::F64(v) => json!(v),
        ScalarValue::Boolean(v) => json!(v),
        ScalarValue::Uint(v) => json!({ "__am": "uint", "v": v.to_string() }),
        ScalarValue::Counter(c) => json!({ "__am": "counter", "v": i64::from(c) }),
        ScalarValue::Timestamp(v) => json!({ "__am": "timestamp", "v": v }),
        ScalarValue::Bytes(b) => json!({ "__am": "bytes", "v": hex::encode(b) }),
        ScalarValue::Null | ScalarValue::Unknown { .. } => Json::Null,
    }
}

fn decode_scalar_wrapper(o: &serde_json::Map<String, Json>) -> Option<ScalarValue> {
    let v = o.get("v")?;
    match o.get("__am")?.as_str()? {
        "uint" => v.as_str()?.parse::<u64>().ok().map(ScalarValue::Uint),
        "counter" => v.as_i64().map(|i| ScalarValue::Counter(i.into())),
        "timestamp" => v.as_i64().map(ScalarValue::Timestamp),
        "bytes" => hex::decode(v.as_str()?).ok().map(ScalarValue::Bytes),
        _ => None,
    }
}

fn scalar_from_json(v: &Json) -> Option<ScalarValue> {
    match v {
        Json::String(s) => Some(ScalarValue::Str(s.as_str().into())),
        Json::Bool(b) => Some(ScalarValue::Boolean(*b)),
        Json::Number(n) => Some(if let Some(i) = n.as_i64() {
            ScalarValue::Int(i)
        } else {
            ScalarValue::F64(n.as_f64().unwrap_or(0.0))
        }),
        Json::Null => Some(ScalarValue::Null),
        Json::Object(o) => decode_scalar_wrapper(o),
        Json::Array(_) => None,
    }
}

fn json_to_scalar(v: &Json) -> ScalarValue {
    scalar_from_json(v).unwrap_or(ScalarValue::Null)
}

/// Both conversions recurse over structures a remote peer controls, so
/// nesting is capped rather than trusted — anything deeper flattens to null
/// instead of overflowing the stack.
const MAX_VALUE_DEPTH: usize = 64;

fn hydrate_to_json(v: &hydrate::Value) -> Json {
    hydrate_to_json_at(v, 0)
}

fn hydrate_to_json_at(v: &hydrate::Value, depth: usize) -> Json {
    if depth >= MAX_VALUE_DEPTH {
        return Json::Null;
    }
    match v {
        hydrate::Value::Scalar(s) => scalar_to_json(s),
        hydrate::Value::Map(m) => {
            let mut out = serde_json::Map::new();
            for (k, entry) in m.iter() {
                out.insert(k.to_string(), hydrate_to_json_at(&entry.value, depth + 1));
            }
            Json::Object(out)
        }
        hydrate::Value::List(l) => Json::Array(
            l.iter()
                .map(|item| hydrate_to_json_at(&item.value, depth + 1))
                .collect(),
        ),
        hydrate::Value::Text(t) => json!(t.to_string()),
    }
}

fn json_to_hydrate(v: &Json) -> hydrate::Value {
    json_to_hydrate_at(v, 0)
}

fn json_to_hydrate_at(v: &Json, depth: usize) -> hydrate::Value {
    if depth >= MAX_VALUE_DEPTH {
        return hydrate::Value::Scalar(ScalarValue::Null);
    }
    match v {
        Json::Object(o) => {
            if let Some(s) = decode_scalar_wrapper(o) {
                return hydrate::Value::Scalar(s);
            }
            let m: std::collections::HashMap<String, hydrate::Value> = o
                .iter()
                .map(|(k, val)| (k.clone(), json_to_hydrate_at(val, depth + 1)))
                .collect();
            hydrate::Value::Map(hydrate::Map::from(m))
        }
        Json::Array(a) => {
            let l: Vec<hydrate::Value> = a
                .iter()
                .map(|item| json_to_hydrate_at(item, depth + 1))
                .collect();
            hydrate::Value::List(hydrate::List::from(l))
        }
        other => hydrate::Value::Scalar(json_to_scalar(other)),
    }
}

pub fn spans_to_json(doc: &Automerge) -> anyhow::Result<Vec<SpanJson>> {
    let Some((_, content)) = doc.get(ROOT, "content")? else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for span in doc.spans(&content)? {
        match span {
            Span::Block(map) => {
                out.push(SpanJson::Block {
                    value: hydrate_to_json(&hydrate::Value::Map(map)),
                });
            }
            Span::Text { text, marks } => {
                let marks = marks.and_then(|set| {
                    let m: serde_json::Map<String, Json> = set
                        .iter()
                        .map(|(name, value)| (name.to_string(), scalar_to_json(value)))
                        .collect();
                    if m.is_empty() {
                        None
                    } else {
                        Some(m)
                    }
                });
                out.push(SpanJson::Text { value: text, marks });
            }
        }
    }
    Ok(out)
}

fn json_spans_to_spans(spans: &[SpanJson]) -> Vec<Span> {
    spans
        .iter()
        .map(|s| match s {
            SpanJson::Block { value } => {
                let hydrate::Value::Map(m) = json_to_hydrate(value) else {
                    return Span::Block(hydrate::Map::default());
                };
                Span::Block(m)
            }
            SpanJson::Text { value, marks } => {
                let marks = marks.as_ref().and_then(|m| {
                    if m.is_empty() {
                        return None;
                    }
                    Some(Arc::new(
                        m.iter()
                            .map(|(k, v)| (k.clone(), json_to_scalar(v)))
                            .collect::<MarkSet>(),
                    ))
                });
                Span::Text {
                    text: value.clone(),
                    marks,
                }
            }
        })
        .collect()
}

const TITLE_CAP: usize = 60;

fn title_space(c: char) -> bool {
    c.is_whitespace()
        && !matches!(
            c,
            '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
}

fn title_line(text: &str) -> Option<String> {
    text.split(['\n', '\r'])
        .map(|line| line.trim_matches(title_space))
        .find(|line| !line.is_empty())
        .map(|line| line.graphemes(true).take(TITLE_CAP).collect())
}

fn is_title_container(value: &Json) -> bool {
    fn tabular(v: &Json) -> bool {
        matches!(
            v.as_str(),
            Some("table" | "table-row" | "table-cell" | "table-header-cell" | "columns" | "column")
        )
    }
    let Some(obj) = value.as_object() else {
        return false;
    };
    obj.get("type").is_some_and(tabular)
        || obj
            .get("parents")
            .and_then(|v| v.as_array())
            .is_some_and(|parents| parents.iter().any(tabular))
}

fn title_from_spans(spans: &[SpanJson]) -> String {
    title_in_spans(spans, true)
        .or_else(|| title_in_spans(spans, false))
        .unwrap_or_default()
}

fn title_in_spans(spans: &[SpanJson], skip_containers: bool) -> Option<String> {
    let mut line = String::new();
    let mut skipping = false;
    for span in spans {
        match span {
            SpanJson::Block { value } => {
                if let Some(title) = title_line(&line) {
                    return Some(title);
                }
                line.clear();
                skipping = skip_containers && is_title_container(value);
            }
            SpanJson::Text { value, .. } => {
                if !skipping {
                    line.push_str(value);
                }
            }
        }
    }
    title_line(&line)
}

pub fn update_spans_from_json_at(
    doc: &mut Automerge,
    spans: &[SpanJson],
    timestamp: i64,
) -> anyhow::Result<bool> {
    let content = match doc.get(ROOT, "content")? {
        Some((_, id)) => id,
        None => tx(doc.transact_with(
            |_| CommitOptions::default().with_time(timestamp),
            |t| t.put_object(ROOT, "content", ObjType::Text),
        ))?,
    };
    let before = doc.get_heads();
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(timestamp),
        |t| {
            t.update_spans(
                &content,
                UpdateSpansConfig::default(),
                json_spans_to_spans(spans),
            )?;
            set_note_title_tx(t, false, &title_from_spans(spans))?;
            Ok::<_, automerge::AutomergeError>(())
        },
    ))?;
    Ok(doc.get_heads() != before)
}

pub fn update_spans_from_json(doc: &mut Automerge, spans: &[SpanJson]) -> anyhow::Result<bool> {
    let content = match doc.get(ROOT, "content")? {
        Some((_, id)) => id,
        None => tx(doc.transact_with(
            |_| CommitOptions::default().with_time(now_seconds()),
            |t| t.put_object(ROOT, "content", ObjType::Text),
        ))?,
    };
    let before = doc.get_heads();
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            t.update_spans(
                &content,
                UpdateSpansConfig::default(),
                json_spans_to_spans(spans),
            )?;
            set_note_title_tx(t, false, &title_from_spans(spans))?;
            Ok(())
        },
    ))?;
    Ok(doc.get_heads() != before)
}

fn content_id(doc: &Automerge) -> anyhow::Result<automerge::ObjId> {
    match doc.get(ROOT, "content")? {
        Some((automerge::Value::Object(ObjType::Text), id)) => Ok(id),
        _ => anyhow::bail!("note has no text content"),
    }
}

/// A stable automerge cursor string for a position in the note text.
/// Matches JS `Automerge.getCursor`: indexes at or past the end become
/// the end cursor.
pub fn text_cursor(doc: &Automerge, index: usize) -> anyhow::Result<String> {
    let content = content_id(doc)?;
    let position = if index >= doc.length(&content) {
        automerge::CursorPosition::End
    } else {
        automerge::CursorPosition::Index(index)
    };
    Ok(doc.get_cursor(&content, position, None)?.to_string())
}

pub fn cursor_index(doc: &Automerge, cursor: &str) -> anyhow::Result<usize> {
    let content = content_id(doc)?;
    let cursor = automerge::Cursor::try_from(cursor)?;
    Ok(doc.get_cursor_position(&content, &cursor, None)?)
}

pub fn splice_note_text(
    doc: &mut Automerge,
    index: usize,
    delete_count: i64,
    insert: &str,
    title: &str,
) -> anyhow::Result<bool> {
    let content = match doc.get(ROOT, "content")? {
        Some((_, id)) => id,
        None => tx(doc.transact_with(
            |_| CommitOptions::default().with_time(now_seconds()),
            |t| t.put_object(ROOT, "content", ObjType::Text),
        ))?,
    };
    let before = doc.get_heads();
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            t.splice_text(&content, index, delete_count as isize, insert)?;
            set_note_title_tx(t, false, title)?;
            Ok(())
        },
    ))?;
    Ok(doc.get_heads() != before)
}

pub fn apply_note_mark(
    doc: &mut Automerge,
    start: usize,
    end: usize,
    name: &str,
    value: Option<Json>,
    title: &str,
) -> anyhow::Result<bool> {
    let content = match doc.get(ROOT, "content")? {
        Some((_, id)) => id,
        None => tx(doc.transact_with(
            |_| CommitOptions::default().with_time(now_seconds()),
            |t| t.put_object(ROOT, "content", ObjType::Text),
        ))?,
    };
    let before = doc.get_heads();
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            if let Some(value) = value {
                t.mark(
                    &content,
                    Mark::new(name.to_string(), json_to_scalar(&value), start, end),
                    ExpandMark::Both,
                )?;
            } else {
                t.unmark(&content, name, start, end, ExpandMark::Both)?;
            }
            set_note_title_tx(t, false, title)?;
            Ok(())
        },
    ))?;
    Ok(doc.get_heads() != before)
}

fn paragraph_block() -> hydrate::Map {
    let m: std::collections::HashMap<String, hydrate::Value> = [
        (
            "type".to_string(),
            hydrate::Value::Scalar("paragraph".into()),
        ),
        (
            "parents".to_string(),
            hydrate::Value::List(hydrate::List::from(Vec::new())),
        ),
        (
            "attrs".to_string(),
            hydrate::Value::Map(hydrate::Map::default()),
        ),
        ("isEmbed".to_string(), hydrate::Value::Scalar(false.into())),
    ]
    .into();
    hydrate::Map::from(m)
}

pub fn init_script(doc: &mut Automerge, name: &str) -> anyhow::Result<()> {
    let filename = if name.is_empty() {
        "script.js".to_string()
    } else if name.ends_with(".js") {
        name.to_string()
    } else {
        format!("{name}.js")
    };
    init_file_doc(doc, &filename, "js", "application/javascript", Vec::new())?;
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let lush = t.put_object(ROOT, "@lush", ObjType::Map)?;
            put_text(t, &lush, "type", "script")?;
            put_text(t, &ROOT, "content", "")?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn lush_type(doc: &Automerge) -> Option<String> {
    let (_, lush) = doc.get(ROOT, "@lush").ok()??;
    string_at(doc, &lush, "type")
}

pub fn init_rich_note(doc: &mut Automerge, title: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let pw = t.put_object(ROOT, "@patchwork", ObjType::Map)?;
            put_text(t, &pw, "type", "rich")?;
            put_text(t, &pw, "title", title)?;
            put_text(t, &pw, "suggestedImportUrl", RICH_TOOL_URL)?;
            put_text(t, &ROOT, "title", title)?;
            let content = t.put_object(ROOT, "content", ObjType::Text)?;
            t.update_spans(
                &content,
                UpdateSpansConfig::default(),
                [Span::Block(paragraph_block())],
            )?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn init_folder(doc: &mut Automerge, title: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let pw = t.put_object(ROOT, "@patchwork", ObjType::Map)?;
            put_text(t, &pw, "type", "folder")?;
            put_text(t, &ROOT, "title", title)?;
            t.put_object(ROOT, "docs", ObjType::List)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn folder_entries(doc: &Automerge) -> anyhow::Result<Vec<DocLink>> {
    let mut out = Vec::new();
    let Some((_, docs)) = doc.get(ROOT, "docs")? else {
        return Ok(out);
    };
    for i in 0..doc.length(&docs) {
        let Some((_, entry)) = doc.get(&docs, i)? else {
            continue;
        };
        out.push(DocLink {
            name: string_at(doc, &entry, "name").unwrap_or_default(),
            kind: string_at(doc, &entry, "type").unwrap_or_default(),
            url: string_at(doc, &entry, "url").unwrap_or_default(),
            lush: string_at(doc, &entry, "lush"),
        });
    }
    Ok(out)
}

/// Link a doc into a folder. `at_top` decides which end it lands at — a
/// newly written note goes wherever the reader asked new notes to go, and
/// everything else keeps the head of the list it has always had.
pub fn add_folder_entry(doc: &mut Automerge, link: &DocLink, at_top: bool) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let docs = match t.get(ROOT, "docs")? {
                Some((_, id)) => id,
                None => t.put_object(ROOT, "docs", ObjType::List)?,
            };
            let index = if at_top { 0 } else { t.length(&docs) };
            let entry = t.insert_object(&docs, index, ObjType::Map)?;
            put_text(t, &entry, "name", &link.name)?;
            put_text(t, &entry, "type", &link.kind)?;
            put_text(t, &entry, "url", &link.url)?;
            if let Some(lush) = &link.lush {
                put_text(t, &entry, "lush", lush)?;
            }
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn remove_folder_entry(doc: &mut Automerge, url: &str) -> anyhow::Result<bool> {
    let entries = folder_entries(doc)?;
    let Some(index) = entries.iter().position(|e| e.url == url) else {
        return Ok(false);
    };
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            if let Some((_, docs)) = t.get(ROOT, "docs")? {
                t.delete(&docs, index)?;
            }
            Ok(())
        },
    ))?;
    Ok(true)
}

/// Bring an entry's name and type in line with what the doc itself says.
/// Returns false when the entry is absent or already correct.
pub fn refresh_folder_entry(
    doc: &mut Automerge,
    url: &str,
    name: &str,
    kind: &str,
) -> anyhow::Result<bool> {
    let entries = folder_entries(doc)?;
    let Some(index) = entries.iter().position(|e| e.url == url) else {
        return Ok(false);
    };
    let entry = &entries[index];
    let new_name = if name.is_empty() {
        entry.name.as_str()
    } else {
        name
    };
    let new_kind = if kind.is_empty() {
        entry.kind.as_str()
    } else {
        kind
    };
    if entry.name == new_name && entry.kind == new_kind {
        return Ok(false);
    }
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            if let Some((_, docs)) = t.get(ROOT, "docs")? {
                if let Some((_, entry)) = t.get(&docs, index)? {
                    set_text(t, &entry, "name", new_name)?;
                    set_identifier(t, &entry, "type", new_kind)?;
                }
            }
            Ok(())
        },
    ))?;
    Ok(true)
}

pub fn rename_folder_entry(doc: &mut Automerge, url: &str, name: &str) -> anyhow::Result<bool> {
    let entries = folder_entries(doc)?;
    let Some(index) = entries.iter().position(|e| e.url == url) else {
        return Ok(false);
    };
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            if let Some((_, docs)) = t.get(ROOT, "docs")? {
                if let Some((_, entry)) = t.get(&docs, index)? {
                    set_text(t, &entry, "name", name)?;
                }
            }
            Ok(())
        },
    ))?;
    Ok(true)
}

fn read_str(doc: &Automerge, obj: &automerge::ObjId, key: &str) -> Option<String> {
    let out = string_at(doc, obj, key)?;
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

// ---- patchwork account + lush config doc ----

pub fn account_field(doc: &Automerge, key: &str) -> Option<String> {
    read_str(doc, &ROOT, key)
}

pub fn account_tools_lush(doc: &Automerge) -> Option<String> {
    let (_, tools) = doc.get(ROOT, "tools").ok()??;
    read_str(doc, &tools, "lush")
}

pub fn set_account_tools_lush(doc: &mut Automerge, url: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let tools = match t.get(ROOT, "tools")? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, "tools", ObjType::Map)?,
            };
            put_text(t, &tools, "lush", url)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn init_lush_config(doc: &mut Automerge) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let pw = t.put_object(ROOT, "@patchwork", ObjType::Map)?;
            put_text(t, &pw, "type", "lush:config")?;
            put_text(t, &pw, "title", "Lush Config")?;
            t.put_object(ROOT, "folders", ObjType::Map)?;
            Ok(())
        },
    ))?;
    Ok(())
}

/// `.folders` is an object keyed by numeric index: `{0: url, 1: url}`.
pub fn config_folders(doc: &Automerge) -> Vec<String> {
    config_url_list(doc, "folders")
}

pub fn config_set_folders(doc: &mut Automerge, urls: &[String]) -> anyhow::Result<()> {
    config_set_url_list(doc, "folders", urls)
}

/// `.packages` holds the extra patchwork package lists, same numeric-index
/// shape as `.folders`.
pub fn config_packages(doc: &Automerge) -> Vec<String> {
    config_url_list(doc, "packages")
}

pub fn config_set_packages(doc: &mut Automerge, urls: &[String]) -> anyhow::Result<()> {
    config_set_url_list(doc, "packages", urls)
}

pub fn config_pins(doc: &Automerge) -> Vec<String> {
    config_url_list(doc, "pins")
}

pub fn config_pins_configured(doc: &Automerge) -> bool {
    doc.get(ROOT, "pins").ok().flatten().is_some()
}

pub fn config_set_pins(doc: &mut Automerge, urls: &[String]) -> anyhow::Result<()> {
    config_set_url_list(doc, "pins", urls)
}

fn config_url_list(doc: &Automerge, key: &str) -> Vec<String> {
    let Ok(Some((_, list))) = doc.get(ROOT, key) else {
        return Vec::new();
    };
    let mut entries: Vec<(u64, String)> = doc
        .keys(&list)
        .filter_map(|key| {
            let index: u64 = key.parse().ok()?;
            let url = read_str(doc, &list, &key)?;
            usable_url(&url).then_some((index, url))
        })
        .collect();
    entries.sort_by_key(|entry| entry.0);
    let mut seen = std::collections::HashSet::new();
    entries
        .into_iter()
        .map(|entry| entry.1)
        .filter(|url| seen.insert(url.clone()))
        .collect()
}

fn config_set_url_list(doc: &mut Automerge, key: &str, urls: &[String]) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let list = match t.get(ROOT, key)? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, key, ObjType::Map)?,
            };
            let stale: Vec<String> = t
                .keys(&list)
                .filter(|key| {
                    key.parse::<usize>()
                        .map(|index| index >= urls.len())
                        .unwrap_or(true)
                })
                .collect();
            for key in stale {
                t.delete(&list, key.as_str())?;
            }
            for (index, url) in urls.iter().enumerate() {
                set_identifier(t, &list, &index.to_string(), url)?;
            }
            Ok(())
        },
    ))?;
    Ok(())
}

/// A url list as the doc stores it, unfiltered — `heads` reads a historical
/// state, `None` the present one.
fn raw_url_list_at(
    doc: &Automerge,
    key: &str,
    heads: Option<&[automerge::ChangeHash]>,
) -> Vec<String> {
    let list = match heads {
        Some(heads) => doc.get_at(ROOT, key, heads).ok().flatten(),
        None => doc.get(ROOT, key).ok().flatten(),
    };
    let Some((_, list)) = list else {
        return Vec::new();
    };
    let keys: Vec<String> = match heads {
        Some(heads) => doc.keys_at(&list, heads).collect(),
        None => doc.keys(&list).collect(),
    };
    let mut entries: Vec<(u64, String)> = keys
        .into_iter()
        .filter_map(|key| {
            let index: u64 = key.parse().ok()?;
            let url = match heads {
                Some(heads) => text_at(doc, &list, &key, heads),
                None => read_str(doc, &list, &key),
            }?;
            Some((index, url))
        })
        .collect();
    entries.sort_by_key(|entry| entry.0);
    entries.into_iter().map(|entry| entry.1).collect()
}

fn text_at(
    doc: &Automerge,
    obj: &automerge::ObjId,
    key: &str,
    heads: &[automerge::ChangeHash],
) -> Option<String> {
    let (v, id) = doc.get_at(obj, key, heads).ok().flatten()?;
    match v {
        automerge::Value::Object(ObjType::Text) => doc.text_at(&id, heads).ok(),
        automerge::Value::Scalar(s) => s.to_str().map(str::to_string),
        _ => None,
    }
}

/// Rebuild url fields the concurrent text diffs fused, out of the doc's own
/// history. Every state a single device wrote holds whole urls, so for a list
/// the most recent single-change state where every entry parses is the last
/// good copy: what still parses in the present keeps its place, and the good
/// copy's urls that went missing come back on the end. Single fields take
/// their most recent parseable value. A doc with nothing wrong writes nothing.
pub fn repair_config_urls(doc: &mut Automerge) -> anyhow::Result<()> {
    const LISTS: [&str; 3] = ["folders", "packages", "pins"];
    const FIELDS: [&str; 3] = ["inbox", "quickNote", "calendar"];

    let broken_lists: Vec<&str> = LISTS
        .into_iter()
        .filter(|key| raw_url_list_at(doc, key, None).iter().any(|url| !usable_url(url)))
        .collect();
    let broken_fields: Vec<&str> = FIELDS
        .into_iter()
        .filter(|key| read_str(doc, &ROOT, key).is_some_and(|url| !usable_url(&url)))
        .collect();
    if broken_lists.is_empty() && broken_fields.is_empty() {
        return Ok(());
    }

    let hashes: Vec<automerge::ChangeHash> =
        doc.get_changes(&[]).iter().map(|change| change.hash()).collect();
    let mut good_lists: std::collections::HashMap<&str, Vec<String>> = Default::default();
    let mut good_fields: std::collections::HashMap<&str, String> = Default::default();
    for hash in hashes.iter().rev() {
        let heads = [*hash];
        for key in &broken_lists {
            if good_lists.contains_key(key) {
                continue;
            }
            let urls = raw_url_list_at(doc, key, Some(&heads));
            if !urls.is_empty() && urls.iter().all(|url| usable_url(url)) {
                good_lists.insert(key, urls);
            }
        }
        for key in &broken_fields {
            if good_fields.contains_key(key) {
                continue;
            }
            if let Some(url) = text_at(doc, &ROOT, key, &heads) {
                if usable_url(&url) {
                    good_fields.insert(key, url);
                }
            }
        }
        if good_lists.len() == broken_lists.len() && good_fields.len() == broken_fields.len() {
            break;
        }
    }

    for key in &broken_lists {
        let mut repaired: Vec<String> = raw_url_list_at(doc, key, None)
            .into_iter()
            .filter(|url| usable_url(url))
            .collect();
        for url in good_lists.get(key).map(Vec::as_slice).unwrap_or_default() {
            if !repaired.contains(url) {
                repaired.push(url.clone());
            }
        }
        let mut seen = std::collections::HashSet::new();
        repaired.retain(|url| seen.insert(url.clone()));
        config_set_url_list(doc, key, &repaired)?;
    }
    if !good_fields.is_empty() {
        tx(doc.transact_with(
            |_| CommitOptions::default().with_time(now_seconds()),
            |t| {
                for (key, url) in &good_fields {
                    set_identifier(t, &ROOT, key, url)?;
                }
                Ok(())
            },
        ))?;
    }
    Ok(())
}

/// A saved search. `rules` is the JSON rule tree the editor writes; the flat
/// `query`/`kind`/`scope`/`within_days` fields carry a best-effort projection
/// of it for clients that predate the tree, and are what those clients wrote.
/// Empty `kind`/`scope` and a zero `within_days` mean "no filter".
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SmartNotebook {
    pub id: String,
    pub name: String,
    pub query: String,
    pub kind: String,
    pub scope: String,
    pub within_days: i64,
    pub show_count: bool,
    pub notify_on_change: bool,
    pub rules: String,
}

/// `.smart` is an object keyed by numeric index, like `.folders`.
pub fn config_smart_notebooks(doc: &Automerge) -> Vec<SmartNotebook> {
    let Ok(Some((_, smart))) = doc.get(ROOT, "smart") else {
        return Vec::new();
    };
    let mut entries: Vec<(u64, SmartNotebook)> = doc
        .keys(&smart)
        .filter_map(|key| {
            let index: u64 = key.parse().ok()?;
            let (_, item) = doc.get(&smart, &key).ok()??;
            Some((
                index,
                SmartNotebook {
                    id: string_at(doc, &item, "id")?,
                    name: string_at(doc, &item, "name").unwrap_or_default(),
                    query: string_at(doc, &item, "query").unwrap_or_default(),
                    kind: string_at(doc, &item, "kind").unwrap_or_default(),
                    scope: string_at(doc, &item, "scope").unwrap_or_default(),
                    within_days: int_at(doc, &item, "withinDays").unwrap_or(0),
                    show_count: bool_at(doc, &item, "showCount").unwrap_or(true),
                    notify_on_change: bool_at(doc, &item, "notifyOnChange").unwrap_or(false),
                    rules: string_at(doc, &item, "rules").unwrap_or_default(),
                },
            ))
        })
        .collect();
    entries.sort_by_key(|entry| entry.0);
    entries.into_iter().map(|entry| entry.1).collect()
}

pub fn config_set_smart_notebooks(
    doc: &mut Automerge,
    folders: &[SmartNotebook],
) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let smart = match t.get(ROOT, "smart")? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, "smart", ObjType::Map)?,
            };
            let stale: Vec<String> = t
                .keys(&smart)
                .filter(|key| {
                    key.parse::<usize>()
                        .map(|index| index >= folders.len())
                        .unwrap_or(true)
                })
                .collect();
            for key in stale {
                t.delete(&smart, key.as_str())?;
            }
            for (index, folder) in folders.iter().enumerate() {
                let key = index.to_string();
                let item = match t.get(&smart, key.as_str())? {
                    Some((automerge::Value::Object(ObjType::Map), id)) => id,
                    _ => t.put_object(&smart, key.as_str(), ObjType::Map)?,
                };
                set_identifier(t, &item, "id", &folder.id)?;
                set_text(t, &item, "name", &folder.name)?;
                set_text(t, &item, "query", &folder.query)?;
                set_text(t, &item, "kind", &folder.kind)?;
                set_text(t, &item, "scope", &folder.scope)?;
                t.put(&item, "withinDays", folder.within_days)?;
                t.put(&item, "showCount", folder.show_count)?;
                t.put(&item, "notifyOnChange", folder.notify_on_change)?;
                set_text(t, &item, "rules", &folder.rules)?;
            }
            Ok(())
        },
    ))?;
    Ok(())
}

/// Per-folder sidebar settings. Only folders that changed a default have an
/// entry; `.folderSettings` is keyed by folder url.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FolderSettings {
    pub url: String,
    pub show_count: bool,
    pub recursive_count: bool,
    pub notify_on_change: bool,
    /// Where a new note goes in this folder, or `None` to follow whatever the
    /// reader set for every folder. Absent from the doc until a folder is
    /// asked to differ.
    pub new_notes_at_top: Option<bool>,
    /// Whether a new note in this folder opens with a logline, or `None` to
    /// follow the reader's answer for every folder.
    pub new_note_logline: Option<bool>,
    /// The block a new note's first line is, as a style key ("heading1",
    /// "paragraph", …), or `None` to follow the reader's answer.
    pub new_note_first_line: Option<String>,
}

pub fn config_folder_settings(doc: &Automerge) -> Vec<FolderSettings> {
    let Ok(Some((_, obj))) = doc.get(ROOT, "folderSettings") else {
        return Vec::new();
    };
    let mut entries: Vec<FolderSettings> = doc
        .keys(&obj)
        .filter_map(|url| {
            let (_, item) = doc.get(&obj, &url).ok()??;
            Some(FolderSettings {
                url,
                show_count: bool_at(doc, &item, "showCount").unwrap_or(false),
                recursive_count: bool_at(doc, &item, "recursiveCount").unwrap_or(false),
                notify_on_change: bool_at(doc, &item, "notifyOnChange").unwrap_or(false),
                new_notes_at_top: bool_at(doc, &item, "newNotesAtTop"),
                new_note_logline: bool_at(doc, &item, "newNoteLogline"),
                new_note_first_line: read_str(doc, &item, "newNoteFirstLine"),
            })
        })
        .collect();
    entries.sort_by(|a, b| a.url.cmp(&b.url));
    entries
}

pub fn config_set_folder_settings(
    doc: &mut Automerge,
    settings: &[FolderSettings],
) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let obj = match t.get(ROOT, "folderSettings")? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, "folderSettings", ObjType::Map)?,
            };
            let stale: Vec<String> = t
                .keys(&obj)
                .filter(|url| !settings.iter().any(|s| &s.url == url))
                .collect();
            for url in stale {
                t.delete(&obj, url.as_str())?;
            }
            for s in settings {
                let item = match t.get(&obj, s.url.as_str())? {
                    Some((automerge::Value::Object(ObjType::Map), id)) => id,
                    _ => t.put_object(&obj, s.url.as_str(), ObjType::Map)?,
                };
                t.put(&item, "showCount", s.show_count)?;
                t.put(&item, "recursiveCount", s.recursive_count)?;
                t.put(&item, "notifyOnChange", s.notify_on_change)?;
                match s.new_notes_at_top {
                    Some(at_top) => t.put(&item, "newNotesAtTop", at_top)?,
                    None => {
                        if t.get(&item, "newNotesAtTop")?.is_some() {
                            t.delete(&item, "newNotesAtTop")?;
                        }
                    }
                }
                match s.new_note_logline {
                    Some(logline) => t.put(&item, "newNoteLogline", logline)?,
                    None => {
                        if t.get(&item, "newNoteLogline")?.is_some() {
                            t.delete(&item, "newNoteLogline")?;
                        }
                    }
                }
                match &s.new_note_first_line {
                    Some(style) => t.put(&item, "newNoteFirstLine", style.as_str())?,
                    None => {
                        if t.get(&item, "newNoteFirstLine")?.is_some() {
                            t.delete(&item, "newNoteFirstLine")?;
                        }
                    }
                }
            }
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn config_inbox(doc: &Automerge) -> Option<String> {
    read_str(doc, &ROOT, "inbox").filter(|url| usable_url(url))
}

pub fn config_set_inbox(doc: &mut Automerge, url: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            set_identifier(t, &ROOT, "inbox", url)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn config_quick_note(doc: &Automerge) -> Option<String> {
    read_str(doc, &ROOT, "quickNote").filter(|url| !url.is_empty())
}

pub fn config_quick_note_configured(doc: &Automerge) -> bool {
    doc.get(ROOT, "quickNote").ok().flatten().is_some()
}

pub fn config_set_quick_note(doc: &mut Automerge, url: Option<&str>) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            set_identifier(t, &ROOT, "quickNote", url.unwrap_or_default())?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn doc_patchwork_type(doc: &Automerge) -> Option<String> {
    let (_, pw) = doc.get(ROOT, "@patchwork").ok()??;
    string_at(doc, &pw, "type")
}

pub fn doc_kind(doc: &Automerge) -> String {
    let kind = doc_patchwork_type(doc).unwrap_or_default();
    if kind == "file" && lush_type(doc).as_deref() == Some("script") {
        "lush:script".into()
    } else {
        kind
    }
}

/// Unix seconds of the newest change. The newest change is always one of the
/// heads, so this reads a handful of changes rather than the whole history.
pub fn doc_modified(doc: &Automerge) -> i64 {
    doc.get_heads()
        .iter()
        .filter_map(|hash| doc.get_change_by_hash(hash))
        .map(|change| change.timestamp())
        .max()
        .unwrap_or(0)
}

/// Unix seconds of the first change. A doc with no timestamped history — an
/// import that carries none — reports 0, which reads as "unknown" rather than
/// as 1970. Reads change metadata only, so no op history is materialized.
pub fn doc_created(doc: &Automerge) -> i64 {
    doc.get_changes_meta(&[])
        .into_iter()
        .map(|change| change.timestamp)
        .find(|stamp| *stamp > 0)
        .unwrap_or(0)
}

pub fn doc_title(doc: &Automerge) -> String {
    if let Some(t) = read_str(doc, &ROOT, "title") {
        return t;
    }
    if let Ok(Some((_, pw))) = doc.get(ROOT, "@patchwork") {
        if let Some(t) = read_str(doc, &pw, "title") {
            return t;
        }
    }
    // file docs store their display name in `name`
    read_str(doc, &ROOT, "name").unwrap_or_default()
}

/// Root `tags`, a list of strings, lowercased and stripped of a leading `#`.
/// Nothing writes it yet; the index carries the concept so the filters have
/// something to read once something does.
pub fn doc_tags(doc: &Automerge) -> Vec<String> {
    let Ok(Some((_, tags))) = doc.get(ROOT, "tags") else {
        return Vec::new();
    };
    (0..doc.length(&tags))
        .filter_map(|i| match doc.get(&tags, i) {
            Ok(Some((automerge::Value::Object(ObjType::Text), id))) => doc.text(&id).ok(),
            Ok(Some((automerge::Value::Scalar(s), _))) => s.to_str().map(str::to_string),
            _ => None,
        })
        .map(|tag| tag.trim().trim_start_matches('#').to_lowercase())
        .filter(|tag| !tag.is_empty() && !tag.contains(' '))
        .collect()
}

/// Root `when`: the day the doc is about, as `YYYY-MM-DD`. Anything longer (a
/// full timestamp) keeps its date part so ordering and range tests still work.
pub fn doc_when(doc: &Automerge) -> String {
    let raw = read_str(doc, &ROOT, "when").unwrap_or_default();
    let day = raw.trim().chars().take(10).collect::<String>();
    let valid = day.len() == 10
        && day.as_bytes()[4] == b'-'
        && day.as_bytes()[7] == b'-'
        && day
            .chars()
            .enumerate()
            .all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit());
    if valid {
        day
    } else {
        String::new()
    }
}

pub fn set_note_title(doc: &mut Automerge, title: &str) -> anyhow::Result<()> {
    if doc_title(doc) == title {
        return Ok(());
    }
    let is_file = doc_patchwork_type(doc).as_deref() == Some("file");
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| set_note_title_tx(t, is_file, title),
    ))?;
    Ok(())
}

fn set_note_title_tx<T: Transactable>(
    t: &mut T,
    is_file: bool,
    title: &str,
) -> Result<(), automerge::AutomergeError> {
    if is_file {
        set_text(t, &ROOT, "name", title)?;
    } else {
        set_text(t, &ROOT, "title", title)?;
        if let Some((_, pw)) = t.get(ROOT, "@patchwork")? {
            set_text(t, &pw, "title", title)?;
        }
    }
    Ok(())
}

/// A patchwork/pushwork UnixFileEntry doc holding binary content.
pub fn init_file_doc(
    doc: &mut Automerge,
    name: &str,
    extension: &str,
    mime_type: &str,
    bytes: Vec<u8>,
) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let pw = t.put_object(ROOT, "@patchwork", ObjType::Map)?;
            put_text(t, &pw, "type", "file")?;
            put_text(t, &ROOT, "name", name)?;
            put_text(t, &ROOT, "extension", extension)?;
            put_text(t, &ROOT, "mimeType", mime_type)?;
            t.put(ROOT, "content", ScalarValue::Bytes(bytes))?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn file_bytes(doc: &Automerge) -> Option<Vec<u8>> {
    let (v, id) = doc.get(ROOT, "content").ok().flatten()?;
    match v {
        automerge::Value::Scalar(s) => match s.as_ref() {
            ScalarValue::Bytes(b) => Some(b.clone()),
            ScalarValue::Str(x) => Some(x.as_bytes().to_vec()),
            _ => None,
        },
        automerge::Value::Object(ObjType::Text) => doc.text(&id).ok().map(String::into_bytes),
        _ => None,
    }
}

/// Automerge URLs of embed/image blocks in a note's content.
pub fn embed_urls(doc: &Automerge) -> Vec<String> {
    let Ok(spans) = spans_to_json(doc) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for span in spans {
        let SpanJson::Block { value } = span else {
            continue;
        };
        let Some(obj) = value.as_object() else {
            continue;
        };
        let is_embed = obj
            .get("isEmbed")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
            || matches!(
                obj.get("type").and_then(|v| v.as_str()),
                Some("embed") | Some("image")
            );
        if !is_embed {
            continue;
        }
        let attrs = obj.get("attrs").and_then(|v| v.as_object());
        let url = attrs
            .and_then(|a| a.get("url").or_else(|| a.get("src")))
            .and_then(|v| v.as_str());
        if let Some(url) = url {
            if url.starts_with("automerge:") {
                out.push(url.to_string());
            }
        }
    }
    out
}

/// Computer-vision metadata on a UnixFileEntry, written by the app when an
/// image is attached.
pub fn set_vision_metadata(
    doc: &mut Automerge,
    description: &str,
    ocr: &str,
) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let cv = match t.get(ROOT, "@computervision")? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, "@computervision", ObjType::Map)?,
            };
            set_text(t, &cv, "description", description)?;
            set_text(t, &cv, "ocr", ocr)?;
            Ok(())
        },
    ))?;
    Ok(())
}

/// Vision / transcription metadata of a file doc, if any has been written.
pub fn asset_vision(doc: &Automerge) -> Option<(String, String)> {
    let (_, cv) = doc.get(ROOT, "@computervision").ok()??;
    let description = read_str(doc, &cv, "description").unwrap_or_default();
    let ocr = read_str(doc, &cv, "ocr").unwrap_or_default();
    if description.is_empty() && ocr.is_empty() {
        None
    } else {
        Some((description, ocr))
    }
}

/// Generated model metadata on a UnixFileEntry, written by local ML passes.
pub fn set_ml_metadata(
    doc: &mut Automerge,
    summary: &str,
    caption: &str,
    keywords: &str,
) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let ml = match t.get(ROOT, "@ml")? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, "@ml", ObjType::Map)?,
            };
            set_text(t, &ml, "summary", summary)?;
            set_text(t, &ml, "caption", caption)?;
            set_text(t, &ml, "keywords", keywords)?;
            Ok(())
        },
    ))?;
    Ok(())
}

/// Generated ML metadata of a file doc, if any has been written.
pub fn asset_ml(doc: &Automerge) -> Option<(String, String, String)> {
    let (_, ml) = doc.get(ROOT, "@ml").ok()??;
    let summary = read_str(doc, &ml, "summary").unwrap_or_default();
    let caption = read_str(doc, &ml, "caption").unwrap_or_default();
    let keywords = read_str(doc, &ml, "keywords").unwrap_or_default();
    if summary.is_empty() && caption.is_empty() && keywords.is_empty() {
        None
    } else {
        Some((summary, caption, keywords))
    }
}

/// Searchable text of a file doc: its name plus any generated metadata.
pub fn asset_search_text(doc: &Automerge) -> String {
    let mut parts = Vec::new();
    if let Some(name) = read_str(doc, &ROOT, "name") {
        parts.push(name);
    }
    if let Ok(Some((_, cv))) = doc.get(ROOT, "@computervision") {
        if let Some(d) = read_str(doc, &cv, "description") {
            parts.push(d);
        }
        if let Some(o) = read_str(doc, &cv, "ocr") {
            parts.push(o);
        }
    }
    if let Ok(Some((_, ml))) = doc.get(ROOT, "@ml") {
        if let Some(summary) = read_str(doc, &ml, "summary") {
            parts.push(summary);
        }
        if let Some(caption) = read_str(doc, &ml, "caption") {
            parts.push(caption);
        }
        if let Some(keywords) = read_str(doc, &ml, "keywords") {
            parts.push(keywords);
        }
    }
    parts.join("\n")
}

// ---- patchwork drafts ----

pub struct CloneShape {
    pub original_url: String,
    pub clone_url: String,
    pub cloned_at: Vec<String>,
    pub merged_at: Option<Vec<String>>,
}

pub struct DraftShape {
    pub is_main: bool,
    pub name: Option<String>,
    pub parent: String,
    pub drafts: Vec<String>,
    pub clones: Vec<CloneShape>,
    pub merged_at: Option<i64>,
}

/// Heads cross the FFI as hex change hashes but live in draft docs as
/// bs58check strings — automerge-repo's `encodeHeads` wire format.
pub(crate) fn head_to_wire(hex: &str) -> String {
    hex::decode(hex)
        .map(|bytes| bs58::encode(bytes).with_check().into_string())
        .unwrap_or_else(|_| hex.to_string())
}

fn head_from_wire(wire: &str) -> String {
    bs58::decode(wire)
        .with_check(None)
        .into_vec()
        .map(hex::encode)
        .unwrap_or_else(|_| wire.to_string())
}

fn put_heads<T: Transactable>(
    t: &mut T,
    obj: &automerge::ObjId,
    key: &str,
    heads: &[String],
) -> Result<(), automerge::AutomergeError> {
    let list = t.put_object(obj, key, ObjType::List)?;
    for (i, head) in heads.iter().enumerate() {
        let item = t.insert_object(&list, i, ObjType::Text)?;
        t.splice_text(&item, 0, 0, &head_to_wire(head))?;
    }
    Ok(())
}

fn string_item(doc: &Automerge, obj: &automerge::ObjId, index: usize) -> Option<String> {
    let (v, id) = doc.get(obj, index).ok().flatten()?;
    match v {
        automerge::Value::Object(ObjType::Text) => doc.text(&id).ok(),
        automerge::Value::Scalar(s) => s.to_str().map(|x| x.to_string()),
        _ => None,
    }
}

fn heads_at(doc: &Automerge, obj: &automerge::ObjId, key: &str) -> Option<Vec<String>> {
    let (v, list) = doc.get(obj, key).ok().flatten()?;
    if !matches!(v, automerge::Value::Object(ObjType::List)) {
        return None;
    }
    Some(
        (0..doc.length(&list))
            .filter_map(|i| string_item(doc, &list, i))
            .map(|wire| head_from_wire(&wire))
            .collect(),
    )
}

fn bool_at(doc: &Automerge, obj: &automerge::ObjId, key: &str) -> Option<bool> {
    let (v, _) = doc.get(obj, key).ok().flatten()?;
    match v {
        automerge::Value::Scalar(s) => match s.as_ref() {
            ScalarValue::Boolean(b) => Some(*b),
            _ => None,
        },
        _ => None,
    }
}

fn int_at(doc: &Automerge, obj: &automerge::ObjId, key: &str) -> Option<i64> {
    let (v, _) = doc.get(obj, key).ok().flatten()?;
    match v {
        automerge::Value::Scalar(s) => match s.as_ref() {
            ScalarValue::Int(i) => Some(*i),
            ScalarValue::Uint(u) => Some(*u as i64),
            ScalarValue::F64(f) => Some(*f as i64),
            ScalarValue::Timestamp(ts) => Some(*ts),
            _ => None,
        },
        _ => None,
    }
}

fn float_at(doc: &Automerge, obj: &automerge::ObjId, key: &str) -> Option<f64> {
    let (v, _) = doc.get(obj, key).ok().flatten()?;
    match v {
        automerge::Value::Scalar(s) => match s.as_ref() {
            ScalarValue::F64(f) => Some(*f),
            ScalarValue::Int(i) => Some(*i as f64),
            ScalarValue::Uint(u) => Some(*u as f64),
            _ => None,
        },
        _ => None,
    }
}

// ---- scratchpad ----

/// One thing parked on a pad. `data` carries the kind's payload as JSON:
/// spans for text, stroke points for ink, an asset url for an image. The
/// geometry stays in native fields so two people rearranging a pad merge.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PadItem {
    pub id: String,
    pub kind: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub data: String,
    pub origin: Option<String>,
    pub created: i64,
}

pub fn init_pad(doc: &mut Automerge, title: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let pw = t.put_object(ROOT, "@patchwork", ObjType::Map)?;
            put_text(t, &pw, "type", "lush:pad")?;
            put_text(t, &pw, "title", title)?;
            put_text(t, &ROOT, "title", title)?;
            let lush = t.put_object(ROOT, "@lush", ObjType::Map)?;
            put_text(t, &lush, "type", "pad")?;
            t.put_object(ROOT, "items", ObjType::List)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn note_pad(doc: &Automerge) -> Option<String> {
    let (_, lush) = doc.get(ROOT, "@lush").ok()??;
    read_str(doc, &lush, "pad")
}

pub fn set_note_pad(doc: &mut Automerge, url: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let lush = match t.get(ROOT, "@lush")? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, "@lush", ObjType::Map)?,
            };
            set_identifier(t, &lush, "pad", url)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn config_calendar(doc: &Automerge) -> Option<String> {
    read_str(doc, &ROOT, "calendar")
}

pub fn config_set_calendar(doc: &mut Automerge, url: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            set_identifier(t, &ROOT, "calendar", url)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn config_pad(doc: &Automerge) -> Option<String> {
    read_str(doc, &ROOT, "pad")
}

pub fn config_set_pad(doc: &mut Automerge, url: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            set_identifier(t, &ROOT, "pad", url)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn pad_items(doc: &Automerge) -> Vec<PadItem> {
    let Ok(Some((_, items))) = doc.get(ROOT, "items") else {
        return Vec::new();
    };
    (0..doc.length(&items))
        .filter_map(|i| {
            let (_, entry) = doc.get(&items, i).ok().flatten()?;
            Some(PadItem {
                id: read_str(doc, &entry, "id")?,
                kind: read_str(doc, &entry, "kind").unwrap_or_else(|| "text".into()),
                x: float_at(doc, &entry, "x").unwrap_or(8.0),
                y: float_at(doc, &entry, "y").unwrap_or(8.0),
                w: float_at(doc, &entry, "w").unwrap_or(184.0),
                h: float_at(doc, &entry, "h").unwrap_or(0.0),
                data: string_at(doc, &entry, "data").unwrap_or_default(),
                origin: read_str(doc, &entry, "origin"),
                created: int_at(doc, &entry, "created").unwrap_or(0),
            })
        })
        .collect()
}

fn pad_index(doc: &Automerge, items: &automerge::ObjId, id: &str) -> Option<usize> {
    (0..doc.length(items)).find(|i| {
        doc.get(items, *i)
            .ok()
            .flatten()
            .and_then(|(_, entry)| read_str(doc, &entry, "id"))
            .as_deref()
            == Some(id)
    })
}

/// Insert an item, or replace the one already carrying its id.
pub fn pad_put_item(doc: &mut Automerge, item: &PadItem) -> anyhow::Result<()> {
    let existing = doc
        .get(ROOT, "items")?
        .and_then(|(_, items)| pad_index(doc, &items, &item.id).map(|i| (items, i)));
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let items = match t.get(ROOT, "items")? {
                Some((automerge::Value::Object(ObjType::List), id)) => id,
                _ => t.put_object(ROOT, "items", ObjType::List)?,
            };
            let entry = match &existing {
                Some((_, index)) => t.put_object(&items, *index, ObjType::Map)?,
                None => t.insert_object(&items, t.length(&items), ObjType::Map)?,
            };
            put_text(t, &entry, "id", &item.id)?;
            put_text(t, &entry, "kind", &item.kind)?;
            t.put(&entry, "x", ScalarValue::F64(item.x))?;
            t.put(&entry, "y", ScalarValue::F64(item.y))?;
            t.put(&entry, "w", ScalarValue::F64(item.w))?;
            t.put(&entry, "h", ScalarValue::F64(item.h))?;
            put_text(t, &entry, "data", &item.data)?;
            if let Some(origin) = &item.origin {
                put_text(t, &entry, "origin", origin)?;
            }
            t.put(&entry, "created", ScalarValue::Int(item.created))?;
            Ok(())
        },
    ))?;
    Ok(())
}

/// Geometry-only update: dragging and resizing must not rewrite the payload,
/// so a card someone else is typing in keeps their text while it moves.
pub fn pad_move_item(
    doc: &mut Automerge,
    id: &str,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) -> anyhow::Result<bool> {
    let Some((items, index)) = doc
        .get(ROOT, "items")?
        .and_then(|(_, items)| pad_index(doc, &items, id).map(|i| (items, i)))
    else {
        return Ok(false);
    };
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            if let Some((_, entry)) = t.get(&items, index)? {
                t.put(&entry, "x", ScalarValue::F64(x))?;
                t.put(&entry, "y", ScalarValue::F64(y))?;
                t.put(&entry, "w", ScalarValue::F64(w))?;
                t.put(&entry, "h", ScalarValue::F64(h))?;
            }
            Ok(())
        },
    ))?;
    Ok(true)
}

pub fn pad_set_data(doc: &mut Automerge, id: &str, data: &str) -> anyhow::Result<bool> {
    let Some((items, index)) = doc
        .get(ROOT, "items")?
        .and_then(|(_, items)| pad_index(doc, &items, id).map(|i| (items, i)))
    else {
        return Ok(false);
    };
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            if let Some((_, entry)) = t.get(&items, index)? {
                set_text(t, &entry, "data", data)?;
            }
            Ok(())
        },
    ))?;
    Ok(true)
}

pub fn pad_remove_item(doc: &mut Automerge, id: &str) -> anyhow::Result<bool> {
    let Some((items, index)) = doc
        .get(ROOT, "items")?
        .and_then(|(_, items)| pad_index(doc, &items, id).map(|i| (items, i)))
    else {
        return Ok(false);
    };
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            t.delete(&items, index)?;
            Ok(())
        },
    ))?;
    Ok(true)
}

pub fn init_draft(doc: &mut Automerge, parent_url: &str, is_main: bool) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let pw = t.put_object(ROOT, "@patchwork", ObjType::Map)?;
            put_text(t, &pw, "type", "draft")?;
            if is_main {
                t.put(ROOT, "isMain", true)?;
            }
            put_text(t, &ROOT, "parent", parent_url)?;
            t.put_object(ROOT, "drafts", ObjType::List)?;
            t.put_object(ROOT, "clones", ObjType::Map)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn draft_add_child(doc: &mut Automerge, child_url: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let drafts = match t.get(ROOT, "drafts")? {
                Some((automerge::Value::Object(ObjType::List), id)) => id,
                _ => t.put_object(ROOT, "drafts", ObjType::List)?,
            };
            let entry = t.insert_object(&drafts, t.length(&drafts), ObjType::Text)?;
            t.splice_text(&entry, 0, 0, child_url)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn draft_set_name(doc: &mut Automerge, name: Option<&str>) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            match name {
                Some(name) => set_text(t, &ROOT, "name", name)?,
                None => {
                    if t.get(ROOT, "name")?.is_some() {
                        t.delete(&ROOT, "name")?;
                    }
                }
            }
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn draft_record_clone(
    doc: &mut Automerge,
    original_url: &str,
    clone_url: &str,
    cloned_at: &[String],
) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let clones = match t.get(ROOT, "clones")? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, "clones", ObjType::Map)?,
            };
            let entry = t.put_object(&clones, original_url, ObjType::Map)?;
            put_text(t, &entry, "cloneUrl", clone_url)?;
            put_heads(t, &entry, "clonedAt", cloned_at)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn draft_record_merge(
    doc: &mut Automerge,
    original_url: &str,
    merged_at: &[String],
) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let Some((automerge::Value::Object(ObjType::Map), clones)) = t.get(ROOT, "clones")?
            else {
                return Ok(());
            };
            let Some((automerge::Value::Object(ObjType::Map), entry)) =
                t.get(&clones, original_url)?
            else {
                return Ok(());
            };
            put_heads(t, &entry, "mergedAt", merged_at)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn draft_mark_merged(doc: &mut Automerge, timestamp_ms: i64) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            t.put(ROOT, "mergedAt", ScalarValue::Int(timestamp_ms))?;
            Ok(())
        },
    ))?;
    Ok(())
}

/// Patchwork's ephemeral `CheckedOutDraft`: `{checkedOut: url|null,
/// at?: {originalUrl: {from, to}}|null}`. The draft overlay provider reads
/// `at[original].to` to pin nested docs while scrubbing.
pub fn init_checkout(doc: &mut Automerge) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            t.put(ROOT, "checkedOut", ScalarValue::Null)?;
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn set_checkout_state(
    doc: &mut Automerge,
    checked_out: Option<&str>,
    pins: Option<&[(String, Vec<String>)]>,
) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            match checked_out {
                Some(url) => set_identifier(t, &ROOT, "checkedOut", url)?,
                None => t.put(ROOT, "checkedOut", ScalarValue::Null)?,
            }
            match pins {
                Some(pins) => {
                    let at = t.put_object(ROOT, "at", ObjType::Map)?;
                    for (original_url, heads) in pins {
                        let entry = t.put_object(&at, original_url, ObjType::Map)?;
                        put_heads(t, &entry, "from", heads)?;
                        put_heads(t, &entry, "to", heads)?;
                    }
                }
                None => t.put(ROOT, "at", ScalarValue::Null)?,
            }
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn draft_shape(doc: &Automerge) -> Option<DraftShape> {
    if doc_patchwork_type(doc).as_deref() != Some("draft") {
        return None;
    }
    let is_main = match doc.get(ROOT, "isMain") {
        Ok(Some((automerge::Value::Scalar(s), _))) => {
            matches!(s.as_ref(), ScalarValue::Boolean(true))
        }
        _ => false,
    };
    let mut drafts = Vec::new();
    if let Ok(Some((automerge::Value::Object(ObjType::List), list))) = doc.get(ROOT, "drafts") {
        for i in 0..doc.length(&list) {
            if let Some(url) = string_item(doc, &list, i) {
                drafts.push(url);
            }
        }
    }
    let mut clones = Vec::new();
    if let Ok(Some((automerge::Value::Object(ObjType::Map), map))) = doc.get(ROOT, "clones") {
        for key in doc.keys(&map) {
            let Ok(Some((automerge::Value::Object(ObjType::Map), entry))) =
                doc.get(&map, key.as_str())
            else {
                continue;
            };
            clones.push(CloneShape {
                original_url: key,
                clone_url: string_at(doc, &entry, "cloneUrl").unwrap_or_default(),
                cloned_at: heads_at(doc, &entry, "clonedAt").unwrap_or_default(),
                merged_at: heads_at(doc, &entry, "mergedAt"),
            });
        }
    }
    Some(DraftShape {
        is_main,
        name: read_str(doc, &ROOT, "name"),
        parent: string_at(doc, &ROOT, "parent").unwrap_or_default(),
        drafts,
        clones,
        merged_at: int_at(doc, &ROOT, "mergedAt"),
    })
}

pub fn main_draft_url(doc: &Automerge) -> Option<String> {
    let (_, pw) = doc.get(ROOT, "@patchwork").ok()??;
    read_str(doc, &pw, "mainDraftUrl")
}

pub fn set_main_draft_url(doc: &mut Automerge, url: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let pw = match t.get(ROOT, "@patchwork")? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, "@patchwork", ObjType::Map)?,
            };
            set_identifier(t, &pw, "mainDraftUrl", url)?;
            Ok(())
        },
    ))?;
    Ok(())
}

/// Second-line preview for the notes list: the text after the title line.
pub fn note_preview(doc: &Automerge) -> String {
    let Ok(spans) = spans_to_json(doc) else {
        return String::new();
    };
    let mut lines: Vec<String> = Vec::new();
    for span in &spans {
        if let SpanJson::Text { value, .. } = span {
            for piece in value.split('\n') {
                let piece = piece.trim();
                if !piece.is_empty() {
                    lines.push(piece.to_string());
                }
            }
        }
    }
    if lines.len() <= 1 {
        return String::new();
    }
    let mut out = lines[1..].join(" ");
    if out.len() > 100 {
        out.truncate(
            out.char_indices()
                .take(100)
                .last()
                .map(|(i, c)| i + c.len_utf8())
                .unwrap_or(100),
        );
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn iso_parsing_and_weekdays_hold() {
        assert_eq!(parse_iso_seconds("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_iso_seconds("2026-08-21T14:03:22Z"),
            Some(1_787_321_002)
        );
        assert_eq!(
            parse_iso_seconds("2026-08-21T14:03:22+02:00"),
            Some(1_787_321_002 - 7_200)
        );
        assert_eq!(parse_iso_seconds("2026-08-21T14:03"), Some(1_787_321_002 - 22));
        assert_eq!(
            parse_iso_seconds("2026-08-21T14:03:22-0700"),
            Some(1_787_321_002 + 25_200)
        );
        assert_eq!(parse_iso_seconds("garbage"), None);
        assert_eq!(parse_iso_seconds("2026-08-21T24:00:00Z"), None);
        assert_eq!(parse_iso_seconds("2026-08-21T14:99:00Z"), None);
        assert_eq!(parse_iso_seconds("2026-08-21T14:03:61Z"), None);
        assert_eq!(parse_iso_seconds("2026-08-21T14:03:22+0X:00"), None);
        assert_eq!(parse_iso_seconds("2026-08-21T14:03:22+2"), None);
        assert_eq!(parse_iso_seconds("20260821T140322Z"), None);
        assert_eq!(weekday_from_ymd(2026, 8, 21), "Friday");
        assert_eq!(weekday_from_ymd(1970, 1, 1), "Thursday");
    }

    use super::*;

    fn link(name: &str) -> DocLink {
        DocLink {
            name: name.into(),
            kind: "rich".into(),
            url: format!("automerge:{name}"),
            lush: None,
        }
    }

    #[test]
    fn an_entry_lands_at_whichever_end_it_was_asked_for() {
        let mut doc = Automerge::new();
        init_folder(&mut doc, "folder").unwrap();
        add_folder_entry(&mut doc, &link("first"), true).unwrap();
        add_folder_entry(&mut doc, &link("onto the top"), true).unwrap();
        add_folder_entry(&mut doc, &link("onto the bottom"), false).unwrap();
        let names: Vec<String> = folder_entries(&doc)
            .unwrap()
            .into_iter()
            .map(|e| e.name)
            .collect();
        assert_eq!(names, ["onto the top", "first", "onto the bottom"]);
    }

    /// A folder with no opinion carries no key at all, so it reads back as
    /// "follow the setting for every folder" rather than as "the bottom".
    #[test]
    fn a_folder_without_a_placement_reads_back_as_none() {
        let mut doc = Automerge::new();
        let settings = FolderSettings {
            url: "automerge:folder".into(),
            show_count: true,
            recursive_count: false,
            notify_on_change: false,
            new_notes_at_top: None,
            new_note_logline: None,
            new_note_first_line: None,
        };
        config_set_folder_settings(&mut doc, std::slice::from_ref(&settings)).unwrap();
        assert_eq!(config_folder_settings(&doc), vec![settings]);
    }

    /// The two new-note overrides answer the same way a placement does: absent
    /// means follow the reader's setting, and clearing one takes the key back
    /// off rather than writing a false or an empty string.
    #[test]
    fn the_new_note_overrides_round_trip_and_can_be_taken_back_off() {
        let mut doc = Automerge::new();
        let mut settings = FolderSettings {
            url: "automerge:folder".into(),
            show_count: false,
            recursive_count: false,
            notify_on_change: false,
            new_notes_at_top: None,
            new_note_logline: Some(false),
            new_note_first_line: Some("paragraph".into()),
        };
        config_set_folder_settings(&mut doc, std::slice::from_ref(&settings)).unwrap();
        let read = &config_folder_settings(&doc)[0];
        assert_eq!(read.new_note_logline, Some(false));
        assert_eq!(read.new_note_first_line.as_deref(), Some("paragraph"));

        settings.new_note_logline = None;
        settings.new_note_first_line = None;
        config_set_folder_settings(&mut doc, std::slice::from_ref(&settings)).unwrap();
        let read = &config_folder_settings(&doc)[0];
        assert_eq!(read.new_note_logline, None);
        assert_eq!(read.new_note_first_line, None);
    }

    #[test]
    fn a_placement_round_trips_and_can_be_taken_back_off() {
        let mut doc = Automerge::new();
        let mut settings = FolderSettings {
            url: "automerge:folder".into(),
            show_count: false,
            recursive_count: false,
            notify_on_change: false,
            new_notes_at_top: Some(true),
            new_note_logline: None,
            new_note_first_line: None,
        };
        config_set_folder_settings(&mut doc, std::slice::from_ref(&settings)).unwrap();
        assert_eq!(
            config_folder_settings(&doc)[0].new_notes_at_top,
            Some(true)
        );

        settings.new_notes_at_top = Some(false);
        config_set_folder_settings(&mut doc, std::slice::from_ref(&settings)).unwrap();
        assert_eq!(
            config_folder_settings(&doc)[0].new_notes_at_top,
            Some(false)
        );

        settings.new_notes_at_top = None;
        config_set_folder_settings(&mut doc, std::slice::from_ref(&settings)).unwrap();
        assert_eq!(config_folder_settings(&doc)[0].new_notes_at_top, None);
    }

    fn field_is_text(doc: &Automerge, obj: &automerge::ObjId, key: &str) -> bool {
        matches!(
            doc.get(obj, key).unwrap(),
            Some((automerge::Value::Object(ObjType::Text), _))
        )
    }

    #[test]
    fn created_is_first_timestamp_and_modified_is_last() {
        let mut doc = Automerge::new();
        doc.transact_with(
            |_| CommitOptions::default().with_time(111),
            |t| t.put(ROOT, "a", 1),
        )
        .unwrap();
        doc.transact_with(
            |_| CommitOptions::default().with_time(222),
            |t| t.put(ROOT, "a", 2),
        )
        .unwrap();
        assert_eq!(doc_created(&doc), 111);
        assert_eq!(doc_modified(&doc), 222);
    }

    #[test]
    fn note_strings_are_text_objects() {
        let mut doc = Automerge::new();
        init_rich_note(&mut doc, "hi").unwrap();
        assert!(field_is_text(&doc, &ROOT, "title"));
        let (_, pw) = doc.get(ROOT, "@patchwork").unwrap().unwrap();
        assert!(field_is_text(&doc, &pw, "type"));
        assert!(field_is_text(&doc, &pw, "title"));
        assert!(field_is_text(&doc, &pw, "suggestedImportUrl"));
        assert_eq!(
            string_at(&doc, &pw, "suggestedImportUrl").as_deref(),
            Some("automerge:2XoPZihn6Vo2aqeVu2WN39W8cdAN")
        );
        assert_eq!(doc_title(&doc), "hi");
    }

    #[test]
    fn normalize_converts_scalars_and_is_idempotent() {
        let mut doc = Automerge::new();
        tx(doc.transact_with(
            |_| CommitOptions::default().with_time(now_seconds()),
            |t| {
                let pw = t.put_object(ROOT, "@patchwork", ObjType::Map)?;
                t.put(&pw, "type", "folder")?;
                t.put(ROOT, "title", "old scalar")?;
                Ok(())
            },
        ))
        .unwrap();
        normalize_strings(&mut doc).unwrap();
        assert!(field_is_text(&doc, &ROOT, "title"));
        assert_eq!(doc_title(&doc), "old scalar");
        let heads = doc.get_heads();
        normalize_strings(&mut doc).unwrap();
        assert_eq!(doc.get_heads(), heads, "second normalize must be a no-op");
    }

    #[test]
    fn file_doc_roundtrip() {
        let mut doc = Automerge::new();
        init_file_doc(&mut doc, "cat.png", "png", "image/png", vec![1, 2, 3]).unwrap();
        assert_eq!(file_bytes(&doc), Some(vec![1, 2, 3]));
    }

    #[test]
    fn config_pins_and_quick_note_roundtrip() {
        let mut doc = Automerge::new();
        init_lush_config(&mut doc).unwrap();
        assert!(!config_pins_configured(&doc));
        assert!(!config_quick_note_configured(&doc));

        let one = crate::repo::DocId::random().to_url();
        let two = crate::repo::DocId::random().to_url();
        let quick = crate::repo::DocId::random().to_url();
        config_set_pins(&mut doc, &[one.clone(), two.clone()]).unwrap();
        config_set_quick_note(&mut doc, Some(&quick)).unwrap();
        assert_eq!(config_pins(&doc), vec![one, two]);
        assert_eq!(config_quick_note(&doc).as_deref(), Some(quick.as_str()));
        assert!(config_pins_configured(&doc));
        assert!(config_quick_note_configured(&doc));

        config_set_pins(&mut doc, &[]).unwrap();
        config_set_quick_note(&mut doc, None).unwrap();
        assert!(config_pins(&doc).is_empty());
        assert_eq!(config_quick_note(&doc), None);
        assert!(config_pins_configured(&doc));
        assert!(config_quick_note_configured(&doc));
    }

    #[test]
    fn deep_nesting_is_capped_not_overflowed() {
        let mut v = json!(1);
        for _ in 0..500 {
            v = json!([v]);
        }
        let hydrated = json_to_hydrate(&v);
        let _ = hydrate_to_json(&hydrated);
    }

    #[test]
    fn draft_doc_shape_and_wire_heads() {
        let mut doc = Automerge::new();
        init_draft(&mut doc, "automerge:parent", false).unwrap();
        assert_eq!(doc_patchwork_type(&doc).as_deref(), Some("draft"));
        assert!(doc.get(ROOT, "isMain").unwrap().is_none());
        let shape = draft_shape(&doc).unwrap();
        assert!(!shape.is_main);
        assert_eq!(shape.parent, "automerge:parent");
        assert!(shape.name.is_none());
        assert!(shape.drafts.is_empty());
        assert!(shape.clones.is_empty());
        assert!(shape.merged_at.is_none());

        let head = "ab".repeat(32);
        draft_record_clone(
            &mut doc,
            "automerge:orig",
            "automerge:clone",
            std::slice::from_ref(&head),
        )
        .unwrap();
        let (_, clones) = doc.get(ROOT, "clones").unwrap().unwrap();
        let (_, entry) = doc.get(&clones, "automerge:orig").unwrap().unwrap();
        let (v, list) = doc.get(&entry, "clonedAt").unwrap().unwrap();
        assert!(matches!(v, automerge::Value::Object(ObjType::List)));
        let (v, item) = doc.get(&list, 0).unwrap().unwrap();
        assert!(matches!(v, automerge::Value::Object(ObjType::Text)));
        let stored = doc.text(&item).unwrap();
        assert_eq!(
            hex::encode(bs58::decode(&stored).with_check(None).into_vec().unwrap()),
            head
        );

        draft_record_merge(&mut doc, "automerge:orig", std::slice::from_ref(&head)).unwrap();
        draft_record_merge(&mut doc, "automerge:missing", std::slice::from_ref(&head)).unwrap();
        let shape = draft_shape(&doc).unwrap();
        assert_eq!(shape.clones.len(), 1);
        assert_eq!(shape.clones[0].original_url, "automerge:orig");
        assert_eq!(shape.clones[0].clone_url, "automerge:clone");
        assert_eq!(shape.clones[0].cloned_at, vec![head.clone()]);
        assert_eq!(shape.clones[0].merged_at, Some(vec![head]));

        let mut note = Automerge::new();
        init_rich_note(&mut note, "hi").unwrap();
        assert!(draft_shape(&note).is_none());
    }

    #[test]
    fn stale_full_save_merges_with_concurrent_insert() {
        let mut base = Automerge::new();
        init_rich_note(&mut base, "hello").unwrap();
        update_spans_from_json(
            &mut base,
            &[
                SpanJson::Block {
                    value: json!({ "type": "paragraph", "parents": [] }),
                },
                SpanJson::Text {
                    value: "hello".into(),
                    marks: None,
                },
            ],
        )
        .unwrap();

        let mut remote = base.fork();
        splice_note_text(&mut remote, 6, 0, " world", "hello world").unwrap();

        let mut stale_save = base.fork();
        update_spans_from_json(
            &mut stale_save,
            &[
                SpanJson::Block {
                    value: json!({ "type": "heading", "parents": [], "attrs": { "level": 1 } }),
                },
                SpanJson::Text {
                    value: "hello".into(),
                    marks: None,
                },
            ],
        )
        .unwrap();

        base.merge(&mut remote).unwrap();
        base.merge(&mut stale_save).unwrap();
        assert_eq!(full_text(&base), "hello world");
    }

    #[test]
    fn text_insert_merges_with_concurrent_mark() {
        let mut base = Automerge::new();
        init_rich_note(&mut base, "hello world").unwrap();
        update_spans_from_json(
            &mut base,
            &[
                SpanJson::Block {
                    value: json!({ "type": "paragraph", "parents": [] }),
                },
                SpanJson::Text {
                    value: "hello world".into(),
                    marks: None,
                },
            ],
        )
        .unwrap();

        let mut inserted = base.fork();
        let mut marked = base.fork();

        // One block marker lives before the visible paragraph text, so visible
        // "hello ".len() maps to Automerge text index 7.
        splice_note_text(&mut inserted, 7, 0, "beautiful ", "hello beautiful world").unwrap();
        apply_note_mark(
            &mut marked,
            1,
            12,
            "strong",
            Some(json!(true)),
            "hello world",
        )
        .unwrap();

        marked.merge(&mut inserted).unwrap();
        let spans = spans_to_json(&marked).unwrap();
        assert_eq!(full_text(&marked), "hello beautiful world");
        let text_spans = spans
            .iter()
            .filter_map(|span| match span {
                SpanJson::Text { value, marks } => Some((value.as_str(), marks)),
                SpanJson::Block { .. } => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(text_spans.len(), 1, "{spans:?}");
        assert_eq!(text_spans[0].0, "hello beautiful world");
        assert_eq!(
            text_spans[0].1.as_ref().and_then(|m| m.get("strong")),
            Some(&json!(true))
        );
    }
}

/// All text content of a note, blocks separated by newlines.
pub fn full_text(doc: &Automerge) -> String {
    let Ok(spans) = spans_to_json(doc) else {
        return String::new();
    };
    let mut out = String::new();
    for span in spans {
        match span {
            SpanJson::Block { .. } => {
                if !out.is_empty() && !out.ends_with('\n') {
                    out.push('\n');
                }
            }
            SpanJson::Text { value, .. } => out.push_str(&value),
        }
    }
    out
}

pub fn context_values(doc: &Automerge, key: &str) -> Vec<String> {
    let Ok(spans) = spans_to_json(doc) else {
        return Vec::new();
    };
    spans
        .into_iter()
        .filter_map(|span| match span {
            SpanJson::Block { value }
                if value.get("type").and_then(Json::as_str) == Some("context") =>
            {
                value
                    .get("attrs")
                    .and_then(Json::as_object)
                    .and_then(|attrs| attrs.get(key))
                    .and_then(Json::as_str)
                    .map(str::to_string)
            }
            _ => None,
        })
        .collect()
}

const WEEKDAYS: [&str; 7] = [
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
];

const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];

fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_prime = (month + 9) % 12;
    let day_of_year = ((153 * month_prime + 2) / 5 + day - 1) as i64;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn iso_ymd(value: &str) -> Option<(i64, u32, u32)> {
    let bytes = value.as_bytes();
    if bytes.get(4) != Some(&b'-') || bytes.get(7) != Some(&b'-') {
        return None;
    }
    let year: i64 = value.get(0..4)?.parse().ok()?;
    let month: u32 = value.get(5..7)?.parse().ok()?;
    let day: u32 = value.get(8..10)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    Some((year, month, day))
}

/// The hour as written in the stamp — the writer's wall clock when the stamp
/// carries an offset, UTC when it ends in Z.
fn iso_hour(value: &str) -> Option<u32> {
    let hour: u32 = value.get(11..13)?.parse().ok()?;
    (hour < 24).then_some(hour)
}

/// A malformed stamp is None, never a guessed instant: this feeds
/// `calendar_event_window`, where a wrong epoch is worse than an absent one.
pub fn parse_iso_seconds(value: &str) -> Option<i64> {
    let (year, month, day) = iso_ymd(value)?;
    let hour: i64 = value.get(11..13)?.parse().ok().filter(|h| *h < 24)?;
    let minute: i64 = value.get(14..16)?.parse().ok().filter(|m| *m < 60)?;
    let second: i64 = match value.as_bytes().get(16) {
        Some(b':') => value.get(17..19)?.parse().ok().filter(|s| *s < 60)?,
        _ => 0,
    };
    let mut seconds = days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second;
    let tail = value.get(16..).unwrap_or_default();
    if let Some(index) = tail.find(['+', '-']) {
        let offset = &tail[index..];
        let sign: i64 = if offset.starts_with('+') { 1 } else { -1 };
        let offset_hours: i64 = offset.get(1..3)?.parse().ok().filter(|h| *h < 24)?;
        let offset_minutes: i64 = match offset.as_bytes().get(3) {
            Some(b':') => offset.get(4..6)?.parse().ok().filter(|m| *m < 60)?,
            Some(b'0'..=b'9') => offset.get(3..5)?.parse().ok().filter(|m| *m < 60)?,
            None => 0,
            _ => return None,
        };
        seconds -= sign * (offset_hours * 3_600 + offset_minutes * 60);
    }
    Some(seconds)
}

fn weekday_from_ymd(year: i64, month: u32, day: u32) -> &'static str {
    WEEKDAYS[days_from_civil(year, month, day).rem_euclid(7) as usize]
}

fn event_search_line(attrs: &serde_json::Map<String, Json>) -> Option<String> {
    let title = attrs.get("title").and_then(Json::as_str)?;
    let mut parts = vec![title.to_string()];
    if let Some(start) = attrs.get("start").and_then(Json::as_str) {
        if let Some((year, month, day)) = iso_ymd(start) {
            parts.push(format!(
                "{} {} {} {}",
                weekday_from_ymd(year, month, day),
                day,
                MONTHS[(month - 1) as usize],
                year
            ));
            if attrs.get("allDay").and_then(Json::as_bool) == Some(true) {
                parts.push("all day".to_string());
            } else if let Some(time) = start.get(11..16) {
                parts.push(time.to_string());
            }
        }
    }
    for key in ["location", "calendar", "repeat"] {
        if let Some(value) = attrs.get(key).and_then(Json::as_str) {
            parts.push(value.to_string());
        }
    }
    parts.push(
        if attrs.get("kind").and_then(Json::as_str) == Some("reminder") {
            "reminder"
        } else {
            "calendar event"
        }
        .to_string(),
    );
    Some(
        parts
            .into_iter()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" · "),
    )
}

/// The searchable text of a note: its text runs plus the lines a reader
/// would consider part of the note but which live in block attrs — calendar
/// events and raw HTML.
pub fn search_text(doc: &Automerge) -> String {
    fn push_line(out: &mut String, line: &str) {
        if line.is_empty() {
            return;
        }
        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        out.push_str(line);
        out.push('\n');
    }
    let Ok(spans) = spans_to_json(doc) else {
        return String::new();
    };
    let mut out = String::new();
    for span in spans {
        match span {
            SpanJson::Block { value } => {
                if !out.is_empty() && !out.ends_with('\n') {
                    out.push('\n');
                }
                let attrs = value.get("attrs").and_then(Json::as_object);
                if value.get("type").and_then(Json::as_str) == Some("calendar-event") {
                    if let Some(line) = attrs.and_then(event_search_line) {
                        push_line(&mut out, &line);
                    }
                }
                if let Some(html) = attrs.and_then(|a| a.get("html")).and_then(Json::as_str) {
                    push_line(&mut out, html);
                }
            }
            SpanJson::Text { value, .. } => out.push_str(&value),
        }
    }
    out
}

fn context_line(attrs: &serde_json::Map<String, Json>) -> String {
    let mut parts = vec!["Logline".to_string()];
    if let Some(raw) = attrs
        .get("created")
        .or_else(|| attrs.get("ts"))
        .and_then(Json::as_str)
    {
        if let Some(hour) = iso_hour(raw) {
            parts.push(
                match hour {
                    5..=11 => "morning daytime",
                    12..=16 => "afternoon daytime",
                    17..=20 => "evening",
                    _ => "night nighttime",
                }
                .to_string(),
            );
        }
        if let Some((year, month, day)) = iso_ymd(raw) {
            parts.push(weekday_from_ymd(year, month, day).to_string());
        }
    }
    if let Some(location) = attrs.get("location").and_then(Json::as_str) {
        parts.push(location.to_string());
    }
    if let Some(weather) = attrs.get("weather").and_then(Json::as_str) {
        parts.push(weather.to_string());
        let value = weather.to_lowercase();
        if ["rain", "drizzle", "shower", "thunder"].iter().any(|w| value.contains(w)) {
            parts.push("wet rainy".to_string());
        }
        if value.contains("clear") || value.contains("sun") {
            parts.push("sunny sunshine".to_string());
        }
        if value.contains("cloud") || value.contains("overcast") {
            parts.push("cloudy".to_string());
        }
        if value.contains("snow") {
            parts.push("snowy cold".to_string());
        }
        if value.contains("fog") || value.contains("mist") {
            parts.push("foggy misty".to_string());
        }
    }
    let reserved = ["created", "ts", "location", "lat", "lon", "weather"];
    for (key, value) in attrs {
        if reserved.contains(&key.as_str()) {
            continue;
        }
        if let Some(text) = value.as_str() {
            parts.push(text.to_string());
        }
    }
    parts.join(" ")
}

/// Loglines rendered as embedding-friendly prose: time-of-day and weather
/// words a person would search by, which the raw attrs don't contain.
pub fn context_search_text(doc: &Automerge) -> String {
    let Ok(spans) = spans_to_json(doc) else {
        return String::new();
    };
    spans
        .into_iter()
        .filter_map(|span| match span {
            SpanJson::Block { value }
                if value.get("type").and_then(Json::as_str) == Some("context") =>
            {
                value
                    .get("attrs")
                    .and_then(Json::as_object)
                    .map(context_line)
            }
            _ => None,
        })
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// The note's first logline, exactly as the sidebar reads it: whatever that
/// one block carries, with no later logline standing in for what it lacks.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FirstContext {
    /// The block's `created` stamp (else its `ts`) as epoch seconds; 0 when it
    /// carries neither, or one that is not an instant.
    pub created: i64,
    pub location: String,
    pub weather: String,
    pub now_playing: String,
}

pub fn first_context(doc: &Automerge) -> FirstContext {
    let Ok(spans) = spans_to_json(doc) else {
        return FirstContext::default();
    };
    spans
        .into_iter()
        .find_map(|span| {
            let SpanJson::Block { value } = span else {
                return None;
            };
            if value.get("type").and_then(Json::as_str) != Some("context") {
                return None;
            }
            let attrs = value.get("attrs").and_then(Json::as_object);
            let text = |key: &str| {
                attrs
                    .and_then(|attrs| attrs.get(key))
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_string()
            };
            let stamp = {
                let created = text("created");
                if created.is_empty() {
                    text("ts")
                } else {
                    created
                }
            };
            Some(FirstContext {
                created: parse_iso_seconds(&stamp).unwrap_or_default(),
                location: text("location"),
                weather: text("weather"),
                now_playing: text("nowPlaying"),
            })
        })
        .unwrap_or_default()
}

/// A logline that carried a fix. The stamp stays the string the block was
/// written with — whoever reads it back knows the format it went in as.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContextPlace {
    pub lat: f64,
    pub lon: f64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub weather: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub ts: String,
}

/// Every logline in the doc that knows where it was stamped. A logline without
/// a fix is nowhere on a map, so it is left out here rather than downstream.
pub fn context_places(doc: &Automerge) -> Vec<ContextPlace> {
    let Ok(spans) = spans_to_json(doc) else {
        return Vec::new();
    };
    spans
        .into_iter()
        .filter_map(|span| {
            let SpanJson::Block { value } = span else {
                return None;
            };
            if value.get("type").and_then(Json::as_str) != Some("context") {
                return None;
            }
            let attrs = value.get("attrs").and_then(Json::as_object)?;
            let text = |key: &str| {
                attrs
                    .get(key)
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_string()
            };
            let created = text("created");
            let lat = attrs.get("lat").and_then(Json::as_f64)?;
            let lon = attrs.get("lon").and_then(Json::as_f64)?;
            // a doc can arrive from anywhere, and two numbers are not yet a
            // place: what is not on the globe never becomes a pin
            if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
                return None;
            }
            Some(ContextPlace {
                lat,
                lon,
                name: text("location"),
                weather: text("weather"),
                ts: if created.is_empty() { text("ts") } else { created },
            })
        })
        .collect()
}

/// Every logline's stamp, in document order, as it was written: an ISO 8601
/// string carrying the offset it was stamped at, so the day it reads as is the
/// day it was written on. A logline with no fix is nowhere on a map but still
/// says when the note was being written, which is all a day needs.
pub fn context_stamps(doc: &Automerge) -> Vec<String> {
    let Ok(spans) = spans_to_json(doc) else {
        return Vec::new();
    };
    spans
        .into_iter()
        .filter_map(|span| {
            let SpanJson::Block { value } = span else {
                return None;
            };
            if value.get("type").and_then(Json::as_str) != Some("context") {
                return None;
            }
            let attrs = value.get("attrs").and_then(Json::as_object)?;
            attrs
                .get("created")
                .or_else(|| attrs.get("ts"))
                .and_then(Json::as_str)
                .filter(|stamp| !stamp.is_empty())
                .map(str::to_string)
        })
        .collect()
}

pub fn calendar_event_ids(doc: &Automerge) -> Vec<String> {
    let Ok(spans) = spans_to_json(doc) else {
        return Vec::new();
    };
    spans
        .into_iter()
        .filter_map(|span| match span {
            SpanJson::Block { value }
                if value.get("type").and_then(Json::as_str) == Some("calendar-event") =>
            {
                value
                    .get("attrs")
                    .and_then(Json::as_object)
                    .and_then(|attrs| attrs.get("event"))
                    .and_then(Json::as_str)
                    .map(str::to_string)
            }
            _ => None,
        })
        .collect()
}

/// The first calendar event's start and end as epoch seconds, 0 when absent.
pub fn calendar_event_window(doc: &Automerge) -> (i64, i64) {
    let Ok(spans) = spans_to_json(doc) else {
        return (0, 0);
    };
    for span in spans {
        if let SpanJson::Block { value } = span {
            if value.get("type").and_then(Json::as_str) != Some("calendar-event") {
                continue;
            }
            let Some(attrs) = value.get("attrs").and_then(Json::as_object) else {
                continue;
            };
            let start = attrs
                .get("start")
                .and_then(Json::as_str)
                .and_then(parse_iso_seconds)
                .unwrap_or(0);
            let end = attrs
                .get("end")
                .and_then(Json::as_str)
                .and_then(parse_iso_seconds)
                .unwrap_or(0);
            return (start, end);
        }
    }
    (0, 0)
}

pub fn doc_facets(doc: &Automerge) -> Vec<String> {
    let kind = doc_kind(doc);
    let mut facets = Vec::new();
    if kind == "file" {
        let mime = doc_field(doc, "mimeType").to_lowercase();
        if let Some(media) = mime.split('/').next().filter(|value| !value.is_empty()) {
            facets.push(media.to_string());
            if media == "audio" {
                facets.push("recording".into());
            }
        }
    } else if !["", "rich", "folder", "lush:script"].contains(&kind.as_str()) {
        facets.push("datatype".into());
        facets.push(kind);
    }
    if let Ok(spans) = spans_to_json(doc) {
        for span in spans {
            let SpanJson::Block { value } = span else {
                continue;
            };
            let Some(kind) = value.get("type").and_then(Json::as_str) else {
                continue;
            };
            if !["paragraph", "heading", "embed"].contains(&kind) {
                facets.push(kind.to_string());
            }
        }
    }
    facets.sort();
    facets.dedup();
    facets
}

/// Case-insensitive substring search returning a snippet around the first
/// match, or None. Works in char space to stay boundary-safe.
pub fn search_snippet(text: &str, query: &str) -> Option<String> {
    let hay: Vec<char> = text.chars().collect();
    let hay_lower: Vec<char> = hay
        .iter()
        .map(|c| c.to_lowercase().next().unwrap_or(*c))
        .collect();
    let needle: Vec<char> = query
        .chars()
        .map(|c| c.to_lowercase().next().unwrap_or(c))
        .collect();
    if needle.is_empty() || hay_lower.len() < needle.len() {
        return None;
    }
    let pos = (0..=hay_lower.len() - needle.len())
        .find(|&i| hay_lower[i..i + needle.len()] == needle[..])?;
    let start = pos.saturating_sub(32);
    let end = (pos + needle.len() + 64).min(hay.len());
    let mut snippet: String = hay[start..end].iter().collect();
    snippet = snippet.split_whitespace().collect::<Vec<_>>().join(" ");
    if start > 0 {
        snippet = format!("…{snippet}");
    }
    if end < hay.len() {
        snippet.push('…');
    }
    Some(snippet)
}

pub fn doc_field(doc: &Automerge, key: &str) -> String {
    read_str(doc, &ROOT, key).unwrap_or_default()
}

#[cfg(test)]
mod context_place_tests {
    use super::*;

    fn doc_with(raw: &str) -> Automerge {
        let mut doc = Automerge::new();
        let spans: Vec<SpanJson> = serde_json::from_str(raw).unwrap();
        update_spans_from_json(&mut doc, &spans).unwrap();
        doc
    }

    #[test]
    fn every_logline_with_a_fix_is_kept_in_order() {
        let doc = doc_with(
            r#"[
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"created":"2026-03-04T09:00:00Z","location":"Glasgow",
                         "weather":"Rain","lat":55.8642,"lon":-4.2518}}},
              {"type":"text","value":"some words"},
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"ts":"2026-03-05T09:00:00Z","location":"London",
                         "lat":51.5072,"lon":-0.1276}}}
            ]"#,
        );
        let places = context_places(&doc);
        assert_eq!(places.len(), 2);
        assert_eq!(places[0].name, "Glasgow");
        assert_eq!(places[0].weather, "Rain");
        assert_eq!(places[0].ts, "2026-03-04T09:00:00Z");
        assert!((places[0].lat - 55.8642).abs() < 0.0001);
        assert_eq!(places[1].name, "London");
        assert_eq!(places[1].weather, "");
        assert_eq!(places[1].ts, "2026-03-05T09:00:00Z");
    }

    #[test]
    fn a_logline_without_a_fix_is_nowhere() {
        let doc = doc_with(
            r#"[
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"created":"2026-03-04T09:00:00Z","location":"Somewhere"}}},
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"created":"2026-03-04T10:00:00Z","lat":55.8642}}},
              {"type":"block","value":{"type":"paragraph","parents":[],"isEmbed":false,"attrs":{}}},
              {"type":"text","value":"words"}
            ]"#,
        );
        assert!(context_places(&doc).is_empty());
    }

    #[test]
    fn every_logline_stamp_is_kept_whether_or_not_it_was_placed() {
        let doc = doc_with(
            r#"[
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"created":"2026-03-04T09:00:00+01:00","location":"Glasgow"}}},
              {"type":"text","value":"some words"},
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"ts":"2026-03-05T09:00:00Z","lat":51.5072,"lon":-0.1276}}},
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"location":"nowhen"}}},
              {"type":"block","value":{"type":"paragraph","parents":[],"isEmbed":false,"attrs":{}}}
            ]"#,
        );
        assert_eq!(
            context_stamps(&doc),
            ["2026-03-04T09:00:00+01:00", "2026-03-05T09:00:00Z"]
        );
    }

    #[test]
    fn a_fix_off_the_globe_is_not_a_place() {
        let doc = doc_with(
            r#"[
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"lat":100.0,"lon":-4.2518}}},
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"lat":55.8642,"lon":181.5}}}
            ]"#,
        );
        assert!(context_places(&doc).is_empty());
    }

    /// The sidebar renders one logline, the first, and reads every field off
    /// that block alone.
    #[test]
    fn the_first_logline_never_borrows_from_a_later_one() {
        let doc = doc_with(
            r#"[
              {"type":"block","value":{"type":"paragraph","parents":[],"isEmbed":false,"attrs":{}}},
              {"type":"text","value":"words"},
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"created":"2026-08-21T14:03:22Z","weather":"Rain",
                         "nowPlaying":"Aphex Twin"}}},
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"ts":"2026-08-22T09:00:00Z","location":"Cork"}}}
            ]"#,
        );
        let first = first_context(&doc);
        assert_eq!(first.created, 1_787_321_002);
        assert_eq!(first.weather, "Rain");
        assert_eq!(first.now_playing, "Aphex Twin");
        assert_eq!(first.location, "");
        assert_eq!(context_values(&doc, "location"), vec!["Cork".to_string()]);
    }

    #[test]
    fn a_logline_stamped_only_with_ts_still_reports_a_created() {
        let doc = doc_with(
            r#"[
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"ts":"2026-08-21T14:03:22Z"}}}
            ]"#,
        );
        assert_eq!(first_context(&doc).created, 1_787_321_002);
        assert_eq!(first_context(&Automerge::new()), FirstContext::default());
    }

    #[test]
    fn a_whole_number_coordinate_still_reads_as_one() {
        let doc = doc_with(
            r#"[
              {"type":"block","value":{"type":"context","parents":[],"isEmbed":true,
                "attrs":{"lat":55,"lon":-4}}}
            ]"#,
        );
        let places = context_places(&doc);
        assert_eq!(places.len(), 1);
        assert_eq!(places[0].lat, 55.0);
        assert_eq!(places[0].lon, -4.0);
        assert_eq!(places[0].ts, "");
    }
}

#[cfg(test)]
mod embed_resize_tests {
    use super::*;

    fn spans_json(raw: &str) -> Vec<SpanJson> {
        serde_json::from_str(raw).unwrap()
    }

    #[test]
    fn embed_block_survives_width_attr_update() {
        let mut doc = Automerge::new();
        let initial = spans_json(
            r#"[
              {"type":"block","value":{"type":"embed","parents":[],"isEmbed":true,
                "attrs":{"url":"automerge:abc","tool":"patternwitch"}}},
              {"type":"block","value":{"type":"paragraph","parents":[],"isEmbed":false,"attrs":{}}},
              {"type":"text","value":"hello"}
            ]"#,
        );
        update_spans_from_json(&mut doc, &initial).unwrap();
        let resized = spans_json(
            r#"[
              {"type":"block","value":{"type":"embed","parents":[],"isEmbed":true,
                "attrs":{"url":"automerge:abc","tool":"patternwitch","width":420.0,"height":300.0}}},
              {"type":"block","value":{"type":"paragraph","parents":[],"isEmbed":false,"attrs":{}}},
              {"type":"text","value":"hello"}
            ]"#,
        );
        update_spans_from_json(&mut doc, &resized).unwrap();
        let out = spans_to_json(&doc).unwrap();
        let json = serde_json::to_string(&out).unwrap();
        assert!(json.contains("\"embed\""), "embed block vanished: {json}");
        assert!(json.contains("automerge:abc"), "embed url vanished: {json}");
        assert!(json.contains("420"), "width attr missing: {json}");
    }
}

#[cfg(test)]
mod title_tests {
    use super::*;

    fn block(kind: &str) -> SpanJson {
        SpanJson::Block {
            value: json!({ "type": kind, "parents": [] }),
        }
    }

    fn nested(kind: &str, parents: Json) -> SpanJson {
        SpanJson::Block {
            value: json!({ "type": kind, "parents": parents }),
        }
    }

    fn text(value: &str) -> SpanJson {
        SpanJson::Text {
            value: value.into(),
            marks: None,
        }
    }

    #[test]
    fn empty_document_has_no_title() {
        assert_eq!(title_from_spans(&[]), "");
    }

    #[test]
    fn blocks_without_text_fall_back_to_empty() {
        assert_eq!(
            title_from_spans(&[block("paragraph"), block("paragraph")]),
            ""
        );
    }

    #[test]
    fn whitespace_only_first_block_is_skipped() {
        assert_eq!(
            title_from_spans(&[
                block("paragraph"),
                text("   \u{a0}\t"),
                block("paragraph"),
                text("Real title"),
            ]),
            "Real title"
        );
    }

    #[test]
    fn blank_line_inside_a_block_is_skipped() {
        assert_eq!(
            title_from_spans(&[block("paragraph"), text("\n \nReal title\nrest")]),
            "Real title"
        );
    }

    #[test]
    fn runs_of_one_paragraph_are_joined() {
        assert_eq!(
            title_from_spans(&[
                nested("heading", json!([])),
                SpanJson::Text {
                    value: "Grocery".into(),
                    marks: Some(serde_json::from_value(json!({ "strong": true })).unwrap()),
                },
                text(" list for Tuesday"),
                block("paragraph"),
                text("milk"),
            ]),
            "Grocery list for Tuesday"
        );
    }

    #[test]
    fn embedded_newline_ends_the_title() {
        assert_eq!(
            title_from_spans(&[block("paragraph"), text("Shopping\nlist")]),
            "Shopping"
        );
    }

    #[test]
    fn leading_media_block_contributes_nothing() {
        assert_eq!(
            title_from_spans(&[
                SpanJson::Block {
                    value: json!({ "type": "image", "parents": [], "attrs": { "url": "automerge:x" } }),
                },
                block("paragraph"),
                text("Trip photos"),
            ]),
            "Trip photos"
        );
    }

    #[test]
    fn table_cells_are_not_the_title() {
        assert_eq!(
            title_from_spans(&[
                block("table"),
                nested("table-row", json!(["table"])),
                nested("table-header-cell", json!(["table", "table-row"])),
                nested("paragraph", json!(["table", "table-row", "table-cell"])),
                text("Qty"),
                nested("table-header-cell", json!(["table", "table-row"])),
                nested("paragraph", json!(["table", "table-row", "table-cell"])),
                text("Item"),
                block("paragraph"),
                text("Shopping for the week"),
            ]),
            "Shopping for the week"
        );
    }

    #[test]
    fn a_table_is_the_title_when_it_is_the_whole_note() {
        assert_eq!(
            title_from_spans(&[
                block("table"),
                nested("table-row", json!(["table"])),
                nested("table-header-cell", json!(["table", "table-row"])),
                nested("paragraph", json!(["table", "table-row", "table-cell"])),
                text("Qty"),
                nested("table-header-cell", json!(["table", "table-row"])),
                nested("paragraph", json!(["table", "table-row", "table-cell"])),
                text("Item"),
            ]),
            "Qty"
        );
    }

    #[test]
    fn a_bare_cell_block_is_still_a_container() {
        assert_eq!(
            title_from_spans(&[
                block("table-cell"),
                text("Qty"),
                block("paragraph"),
                text("Shopping"),
            ]),
            "Shopping"
        );
    }

    #[test]
    fn a_table_nested_in_a_list_is_still_a_container() {
        assert_eq!(
            title_from_spans(&[
                nested("table", json!(["bullet-list", "list-item"])),
                nested("table-row", json!(["bullet-list", "list-item", "table"])),
                nested(
                    "table-cell",
                    json!(["bullet-list", "list-item", "table", "table-row"])
                ),
                text("Qty"),
                block("paragraph"),
                text("Shopping for the week"),
            ]),
            "Shopping for the week"
        );
    }

    #[test]
    fn columns_are_not_the_title() {
        assert_eq!(
            title_from_spans(&[
                block("columns"),
                nested("column", json!(["columns"])),
                nested("paragraph", json!(["columns", "column"])),
                text("left"),
                block("paragraph"),
                text("After the columns"),
            ]),
            "After the columns"
        );
    }

    #[test]
    fn columns_are_the_title_when_they_are_the_whole_note() {
        assert_eq!(
            title_from_spans(&[
                block("columns"),
                nested("column", json!(["columns"])),
                nested("paragraph", json!(["columns", "column"])),
                text("left"),
            ]),
            "left"
        );
    }

    #[test]
    fn a_carriage_return_ends_the_title() {
        assert_eq!(
            title_from_spans(&[block("paragraph"), text("Line one\r\nLine two")]),
            "Line one"
        );
        assert_eq!(
            title_from_spans(&[block("paragraph"), text("Line one\rLine two")]),
            "Line one"
        );
    }

    #[test]
    fn title_at_the_cap_is_kept_whole() {
        let line = "a".repeat(TITLE_CAP);
        let title = title_from_spans(&[block("paragraph"), text(&line)]);
        assert_eq!(title, line);
        assert_eq!(title.chars().count(), TITLE_CAP);
    }

    #[test]
    fn title_past_the_cap_is_truncated() {
        let line = "a".repeat(TITLE_CAP + 14);
        assert_eq!(
            title_from_spans(&[block("paragraph"), text(&line)]),
            "a".repeat(TITLE_CAP)
        );
    }

    #[test]
    fn the_cap_counts_graphemes() {
        let line = format!("{}👍👍", "a".repeat(TITLE_CAP - 1));
        let title = title_from_spans(&[block("paragraph"), text(&line)]);
        assert_eq!(title, format!("{}👍", "a".repeat(TITLE_CAP - 1)));

        let zwj = format!("{}👨‍👩‍👧extra", "a".repeat(TITLE_CAP - 1));
        let title = title_from_spans(&[block("paragraph"), text(&zwj)]);
        assert_eq!(title, format!("{}👨‍👩‍👧", "a".repeat(TITLE_CAP - 1)));
        assert_eq!(title.graphemes(true).count(), TITLE_CAP);

        let accented = format!("{}e\u{301}xtra", "a".repeat(TITLE_CAP - 1));
        let title = title_from_spans(&[block("paragraph"), text(&accented)]);
        assert_eq!(title, format!("{}e\u{301}", "a".repeat(TITLE_CAP - 1)));
    }

    #[test]
    fn cap_counts_after_trimming() {
        let line = format!("  {}  ", "a".repeat(TITLE_CAP));
        assert_eq!(
            title_from_spans(&[block("paragraph"), text(&line)]),
            "a".repeat(TITLE_CAP)
        );
    }

    #[test]
    fn line_separators_are_not_trimmed() {
        assert_eq!(
            title_from_spans(&[block("paragraph"), text("Title\u{2028}")]),
            "Title\u{2028}"
        );
    }
}

#[cfg(test)]
mod pad_tests {
    use super::*;

    fn item(id: &str) -> PadItem {
        PadItem {
            id: id.into(),
            kind: "text".into(),
            x: 8.0,
            y: 8.0,
            w: 184.0,
            h: 40.0,
            data: "[]".into(),
            origin: None,
            created: 1,
        }
    }

    #[test]
    fn items_move_and_edit_by_id() {
        let mut doc = Automerge::new();
        init_pad(&mut doc, "pad").unwrap();
        pad_put_item(&mut doc, &item("a")).unwrap();
        pad_put_item(&mut doc, &item("b")).unwrap();
        assert!(pad_move_item(&mut doc, "b", 100.0, 200.0, 300.0, 400.0).unwrap());
        assert!(pad_set_data(&mut doc, "b", "[1]").unwrap());
        let items = pad_items(&doc);
        assert_eq!(items.len(), 2);
        let b = items.iter().find(|i| i.id == "b").unwrap();
        assert_eq!((b.x, b.y, b.w, b.h), (100.0, 200.0, 300.0, 400.0));
        assert_eq!(b.data, "[1]");
        assert!(pad_remove_item(&mut doc, "a").unwrap());
        assert_eq!(pad_items(&doc).len(), 1);
    }

    /// Two devices rewriting the folder list at once — a reorder against an
    /// append — must merge to whole urls from one side or the other. The
    /// character diff `set_text` runs merged the two spellings of an index
    /// into a url neither device wrote.
    #[test]
    fn concurrent_folder_list_writes_stay_whole_urls() {
        use crate::repo::DocId;
        let urls: Vec<String> = (0..3).map(|_| DocId::random().to_url()).collect();
        let mut doc = Automerge::new();
        init_lush_config(&mut doc).unwrap();
        config_set_folders(&mut doc, &urls).unwrap();
        let mut fork = doc.fork();

        let extra = DocId::random().to_url();
        let ours = vec![urls[2].clone(), urls[0].clone(), urls[1].clone()];
        let theirs = vec![
            urls[1].clone(),
            urls[2].clone(),
            urls[0].clone(),
            extra.clone(),
        ];
        config_set_folders(&mut doc, &ours).unwrap();
        config_set_folders(&mut fork, &theirs).unwrap();
        doc.merge(&mut fork).unwrap();

        // The raw entries, not `config_folders`: the read path filters what
        // it can't parse, and the point here is that nothing unparseable got
        // written in the first place.
        let known: std::collections::HashSet<&String> = urls.iter().chain([&extra]).collect();
        let (_, list) = doc.get(ROOT, "folders").unwrap().unwrap();
        for key in doc.keys(&list) {
            let url = read_str(&doc, &list, &key).unwrap();
            assert!(known.contains(&url), "merge invented a url: {url}");
        }
        let merged = config_folders(&doc);
        let unique: std::collections::HashSet<&String> = merged.iter().collect();
        assert_eq!(unique.len(), merged.len(), "duplicate urls: {merged:?}");
    }

    /// A config that already took the damage gets its urls back from its own
    /// history: what still parses keeps its place, the fused entry's original
    /// comes back on the end, and a second run writes nothing.
    #[test]
    fn a_damaged_config_repairs_from_history() {
        use crate::repo::DocId;
        let urls: Vec<String> = (0..3).map(|_| DocId::random().to_url()).collect();
        let mut doc = Automerge::new();
        init_lush_config(&mut doc).unwrap();
        config_set_folders(&mut doc, &urls).unwrap();
        config_set_inbox(&mut doc, &urls[0]).unwrap();

        // fuse entry 1 and the inbox the way the old concurrent diffs did
        tx(doc.transact_with(
            |_| CommitOptions::default().with_time(now_seconds()),
            |t| {
                let (_, list) = t.get(ROOT, "folders")?.unwrap();
                let (_, entry) = t.get(&list, "1")?.unwrap();
                t.splice_text(&entry, 12, 0, "2")?;
                let (_, inbox) = t.get(ROOT, "inbox")?.unwrap();
                t.splice_text(&inbox, 12, 0, "2")?;
                Ok(())
            },
        ))
        .unwrap();
        assert_eq!(config_folders(&doc), vec![urls[0].clone(), urls[2].clone()]);
        assert_eq!(config_inbox(&doc), None);

        repair_config_urls(&mut doc).unwrap();
        assert_eq!(
            config_folders(&doc),
            vec![urls[0].clone(), urls[2].clone(), urls[1].clone()]
        );
        assert_eq!(config_inbox(&doc).as_deref(), Some(urls[0].as_str()));

        let heads = doc.get_heads();
        repair_config_urls(&mut doc).unwrap();
        assert_eq!(doc.get_heads(), heads);
    }

    /// A list that already took the damage reads back healed: the chimera url
    /// is dropped and a doubled root collapses to one.
    #[test]
    fn a_corrupted_url_list_reads_back_usable() {
        use crate::repo::DocId;
        let good = DocId::random().to_url();
        let chimera = format!("automerge:2{}", good.trim_start_matches("automerge:"));
        let mut doc = Automerge::new();
        init_lush_config(&mut doc).unwrap();
        config_set_folders(&mut doc, &[good.clone(), chimera, good.clone()]).unwrap();
        assert_eq!(config_folders(&doc), vec![good]);
    }
}
