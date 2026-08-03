use std::path::Path;
use std::sync::Mutex;

use anyhow::Result;
use rusqlite::{params, Connection};

use crate::api::SearchHit;
use crate::shapes;

pub struct SearchIndex {
    conn: Mutex<Connection>,
}

#[derive(Debug, Clone)]
pub struct IndexedDoc {
    pub url: String,
    pub kind: String,
    pub title: String,
    pub body: String,
    pub links: Vec<String>,
}

impl SearchIndex {
    pub fn open(data_dir: &Path) -> Result<Self> {
        let db_path = data_dir.join("search.sqlite3");
        let conn = Connection::open(db_path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS search_docs (
                url TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS search_docs_fts USING fts5(
                url UNINDEXED,
                kind UNINDEXED,
                title,
                body,
                tokenize = 'unicode61'
            );
            CREATE TABLE IF NOT EXISTS search_links (
                note_url TEXT NOT NULL,
                note_name TEXT NOT NULL,
                asset_url TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS search_links_asset_url
                ON search_links(asset_url);
            "#,
        )?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn upsert(&self, doc: IndexedDoc) -> Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO search_docs(url, kind, title, body)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(url) DO UPDATE SET
                kind = excluded.kind,
                title = excluded.title,
                body = excluded.body",
            params![doc.url, doc.kind, doc.title, doc.body],
        )?;
        tx.execute(
            "DELETE FROM search_docs_fts WHERE url = ?1",
            params![doc.url],
        )?;
        tx.execute(
            "INSERT INTO search_docs_fts(url, kind, title, body) VALUES (?1, ?2, ?3, ?4)",
            params![doc.url, doc.kind, doc.title, doc.body],
        )?;
        if doc.kind == "rich" {
            tx.execute(
                "DELETE FROM search_links WHERE note_url = ?1",
                params![doc.url],
            )?;
            for asset_url in &doc.links {
                tx.execute(
                    "INSERT INTO search_links(note_url, note_name, asset_url)
                     VALUES (?1, ?2, ?3)",
                    params![doc.url, doc.title, asset_url],
                )?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn remove(&self, url: &str) -> Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM search_docs WHERE url = ?1", params![url])?;
        tx.execute("DELETE FROM search_docs_fts WHERE url = ?1", params![url])?;
        tx.execute("DELETE FROM search_links WHERE note_url = ?1", params![url])?;
        tx.commit()?;
        Ok(())
    }

    pub fn search(&self, query: &str) -> Result<Vec<SearchHit>> {
        let Some(fts_query) = fts_query(query) else {
            return Ok(Vec::new());
        };
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT url, kind, title, body
             FROM search_docs_fts
             WHERE search_docs_fts MATCH ?1
             ORDER BY rank
             LIMIT 200",
        )?;
        let mut rows = stmt.query(params![fts_query])?;
        let mut hits = Vec::new();
        let mut seen_notes = std::collections::HashSet::new();
        while let Some(row) = rows.next()? {
            let url: String = row.get(0)?;
            let kind: String = row.get(1)?;
            let title: String = row.get(2)?;
            let body: String = row.get(3)?;
            if kind == "rich" {
                if seen_notes.insert(url.clone()) {
                    hits.push(SearchHit {
                        url,
                        name: title.clone(),
                        snippet: snippet(&body, &title, query),
                    });
                }
            } else if kind == "file" {
                let mut links = conn.prepare(
                    "SELECT note_url, note_name
                     FROM search_links
                     WHERE asset_url = ?1
                     LIMIT 20",
                )?;
                let mut linked_rows = links.query(params![url])?;
                while let Some(linked) = linked_rows.next()? {
                    let note_url: String = linked.get(0)?;
                    let note_name: String = linked.get(1)?;
                    if seen_notes.insert(note_url.clone()) {
                        hits.push(SearchHit {
                            url: note_url,
                            name: note_name,
                            snippet: snippet(&body, &title, query),
                        });
                    }
                }
            }
        }
        Ok(hits)
    }
}

pub fn indexed_doc(url: String, doc: &automerge::Automerge) -> IndexedDoc {
    let kind = shapes::doc_kind(doc);
    let title = shapes::doc_title(doc);
    let body = match kind.as_str() {
        "rich" => shapes::full_text(doc),
        "file" => shapes::asset_search_text(doc),
        _ => String::new(),
    };
    let links = if kind == "rich" {
        shapes::embed_urls(doc)
    } else {
        Vec::new()
    };
    IndexedDoc {
        url,
        kind,
        title,
        body,
        links,
    }
}

fn fts_query(query: &str) -> Option<String> {
    let terms: Vec<String> = query
        .split_whitespace()
        .filter_map(|term| {
            let cleaned: String = term.chars().filter(|c| c.is_alphanumeric()).collect();
            if cleaned.is_empty() {
                None
            } else {
                Some(format!("{}*", cleaned))
            }
        })
        .collect();
    if terms.is_empty() {
        None
    } else {
        Some(terms.join(" "))
    }
}

fn snippet(body: &str, title: &str, query: &str) -> String {
    shapes::search_snippet(body, query)
        .or_else(|| shapes::search_snippet(title, query))
        .unwrap_or_else(|| {
            let mut out = body.split_whitespace().collect::<Vec<_>>().join(" ");
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
        })
}
