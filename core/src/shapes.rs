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

pub const RICH_TOOL_URL: &str =
    "automerge:2XoPZihn6Vo2aqeVu2WN39W8cdAN#28JkzFqXzKReCZ3DGo81Z4QbCUnxcPh7uy84e2wY4FZNT8M2xq";

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

fn scalar_to_json(s: &ScalarValue) -> Json {
    match s {
        ScalarValue::Str(v) => json!(v.as_str()),
        ScalarValue::Int(v) => json!(v),
        ScalarValue::Uint(v) => json!(v),
        ScalarValue::F64(v) => json!(v),
        ScalarValue::Boolean(v) => json!(v),
        ScalarValue::Counter(c) => json!(i64::from(c)),
        ScalarValue::Timestamp(v) => json!(v),
        ScalarValue::Bytes(b) => json!(hex::encode(b)),
        ScalarValue::Null | ScalarValue::Unknown { .. } => Json::Null,
    }
}

fn json_to_scalar(v: &Json) -> ScalarValue {
    match v {
        Json::String(s) => ScalarValue::Str(s.as_str().into()),
        Json::Bool(b) => ScalarValue::Boolean(*b),
        Json::Number(n) => {
            if let Some(i) = n.as_i64() {
                ScalarValue::Int(i)
            } else {
                ScalarValue::F64(n.as_f64().unwrap_or(0.0))
            }
        }
        _ => ScalarValue::Null,
    }
}

fn hydrate_to_json(v: &hydrate::Value) -> Json {
    match v {
        hydrate::Value::Scalar(s) => scalar_to_json(s),
        hydrate::Value::Map(m) => {
            let mut out = serde_json::Map::new();
            for (k, entry) in m.iter() {
                out.insert(k.to_string(), hydrate_to_json(&entry.value));
            }
            Json::Object(out)
        }
        hydrate::Value::List(l) => {
            Json::Array(l.iter().map(|item| hydrate_to_json(&item.value)).collect())
        }
        hydrate::Value::Text(t) => json!(t.to_string()),
    }
}

fn json_to_hydrate(v: &Json) -> hydrate::Value {
    match v {
        Json::Object(o) => {
            let m: std::collections::HashMap<String, hydrate::Value> = o
                .iter()
                .map(|(k, val)| (k.clone(), json_to_hydrate(val)))
                .collect();
            hydrate::Value::Map(hydrate::Map::from(m))
        }
        Json::Array(a) => {
            let l: Vec<hydrate::Value> = a.iter().map(json_to_hydrate).collect();
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

fn title_from_spans(spans: &[SpanJson]) -> String {
    let mut title = String::new();
    let mut seen_text = false;
    for span in spans {
        match span {
            SpanJson::Block { .. } if seen_text => break,
            SpanJson::Block { .. } => {}
            SpanJson::Text { value, .. } => {
                seen_text = true;
                title.push_str(value);
            }
        }
    }
    title.trim().to_string()
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

pub fn add_folder_entry(doc: &mut Automerge, link: &DocLink) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let docs = match t.get(ROOT, "docs")? {
                Some((_, id)) => id,
                None => t.put_object(ROOT, "docs", ObjType::List)?,
            };
            let entry = t.insert_object(&docs, t.length(&docs), ObjType::Map)?;
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
                    set_text(t, &entry, "type", new_kind)?;
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
    let Ok(Some((_, folders))) = doc.get(ROOT, "folders") else {
        return Vec::new();
    };
    let mut entries: Vec<(u64, String)> = doc
        .keys(&folders)
        .filter_map(|key| {
            let index: u64 = key.parse().ok()?;
            let url = read_str(doc, &folders, &key)?;
            Some((index, url))
        })
        .collect();
    entries.sort_by_key(|entry| entry.0);
    entries.into_iter().map(|entry| entry.1).collect()
}

pub fn config_set_folders(doc: &mut Automerge, urls: &[String]) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            let folders = match t.get(ROOT, "folders")? {
                Some((automerge::Value::Object(ObjType::Map), id)) => id,
                _ => t.put_object(ROOT, "folders", ObjType::Map)?,
            };
            let stale: Vec<String> = t
                .keys(&folders)
                .filter(|key| {
                    key.parse::<usize>()
                        .map(|index| index >= urls.len())
                        .unwrap_or(true)
                })
                .collect();
            for key in stale {
                t.delete(&folders, key.as_str())?;
            }
            for (index, url) in urls.iter().enumerate() {
                set_text(t, &folders, &index.to_string(), url)?;
            }
            Ok(())
        },
    ))?;
    Ok(())
}

pub fn config_inbox(doc: &Automerge) -> Option<String> {
    read_str(doc, &ROOT, "inbox")
}

pub fn config_set_inbox(doc: &mut Automerge, url: &str) -> anyhow::Result<()> {
    tx(doc.transact_with(
        |_| CommitOptions::default().with_time(now_seconds()),
        |t| {
            set_text(t, &ROOT, "inbox", url)?;
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
    use super::*;

    fn field_is_text(doc: &Automerge, obj: &automerge::ObjId, key: &str) -> bool {
        matches!(
            doc.get(obj, key).unwrap(),
            Some((automerge::Value::Object(ObjType::Text), _))
        )
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
