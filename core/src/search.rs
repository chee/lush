use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;

use anyhow::Result;
use rusqlite::{params, Connection};

use crate::api::{EmbeddingChunk, RecentNote, SearchHit};
use crate::shapes;

/// Cosine below this is noise rather than a weak match.
const MIN_SEMANTIC_SCORE: f32 = 0.36;

fn encode_vector(vector: &[f32]) -> Vec<u8> {
    vector.iter().flat_map(|v| v.to_le_bytes()).collect()
}

/// Dot product of a query vector against a stored little-endian f32 blob.
/// A blob of the wrong length scores 0 rather than failing the whole scan.
fn dot(query: &[f32], stored: &[u8]) -> f32 {
    if stored.len() != query.len() * 4 {
        return 0.0;
    }
    query
        .iter()
        .zip(stored.chunks_exact(4))
        .map(|(q, bytes)| q * f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
        .sum()
}

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
    pub modified: i64,
    /// File docs only: whether `@computervision` has been written yet.
    pub has_vision: bool,
}

impl SearchIndex {
    pub fn open(data_dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(data_dir)?;
        let db_path = data_dir.join("search.sqlite3");
        let conn = Connection::open(&db_path).or_else(|_| {
            let _ = std::fs::remove_file(&db_path);
            Connection::open(&db_path)
        })?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS search_docs (
                url TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                modified INTEGER NOT NULL DEFAULT 0
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
            CREATE TABLE IF NOT EXISTS embedding_docs (
                url TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                digest TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS embeddings (
                url TEXT NOT NULL,
                chunk INTEGER NOT NULL,
                text TEXT NOT NULL,
                vector BLOB NOT NULL,
                PRIMARY KEY (url, chunk)
            );
            "#,
        )?;
        // Pre-existing databases were created without `modified`; the error on
        // a second run is "duplicate column name" and is the expected outcome.
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN modified INTEGER NOT NULL DEFAULT 0",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN has_vision INTEGER NOT NULL DEFAULT 0",
            [],
        );
        // Deliberately never written by `upsert`: an asset the analyzer already
        // looked at and got nothing from must stay skipped across reindexes,
        // or the backfill retries the same audio files forever.
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN vision_attempted INTEGER NOT NULL DEFAULT 0",
            [],
        );
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS search_docs_modified
                ON search_docs(modified DESC);",
        )?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn upsert(&self, doc: IndexedDoc) -> Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO search_docs(url, kind, title, body, modified, has_vision)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(url) DO UPDATE SET
                kind = excluded.kind,
                title = excluded.title,
                body = excluded.body,
                modified = excluded.modified,
                has_vision = excluded.has_vision",
            params![
                doc.url,
                doc.kind,
                doc.title,
                doc.body,
                doc.modified,
                doc.has_vision
            ],
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
        tx.execute("DELETE FROM embedding_docs WHERE url = ?1", params![url])?;
        tx.execute("DELETE FROM embeddings WHERE url = ?1", params![url])?;
        tx.commit()?;
        Ok(())
    }

    /// Replace a note's embedding chunks. `digest` identifies the text they
    /// were built from, so an unchanged note can skip re-embedding entirely.
    pub fn set_embeddings(
        &self,
        url: &str,
        name: &str,
        digest: &str,
        chunks: &[EmbeddingChunk],
    ) -> Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO embedding_docs(url, name, digest)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(url) DO UPDATE SET
                name = excluded.name,
                digest = excluded.digest",
            params![url, name, digest],
        )?;
        tx.execute("DELETE FROM embeddings WHERE url = ?1", params![url])?;
        for (i, chunk) in chunks.iter().enumerate() {
            tx.execute(
                "INSERT INTO embeddings(url, chunk, text, vector)
                 VALUES (?1, ?2, ?3, ?4)",
                params![url, i as i64, chunk.text, encode_vector(&chunk.vector)],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn remove_embeddings(&self, url: &str) -> Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM embedding_docs WHERE url = ?1", params![url])?;
        tx.execute("DELETE FROM embeddings WHERE url = ?1", params![url])?;
        tx.commit()?;
        Ok(())
    }

    pub fn mark_vision_attempted(&self, url: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE search_docs SET vision_attempted = 1 WHERE url = ?1",
            params![url],
        )?;
        Ok(())
    }

    /// File docs that have been indexed, carry no vision metadata, and have not
    /// already been through the analyzer.
    pub fn assets_without_vision(&self, limit: u32) -> Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT url FROM search_docs
             WHERE kind = 'file' AND has_vision = 0 AND vision_attempted = 0
             LIMIT ?1",
        )?;
        let mut rows = stmt.query(params![limit])?;
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            out.push(row.get(0)?);
        }
        Ok(out)
    }

    pub fn embedding_digest(&self, url: &str) -> Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT digest FROM embedding_docs WHERE url = ?1")?;
        let mut rows = stmt.query(params![url])?;
        Ok(match rows.next()? {
            Some(row) => Some(row.get(0)?),
            None => None,
        })
    }

    /// url -> digest for every embedded note, so a backfill can skip the ones
    /// whose text has not moved.
    pub fn embedding_digests(&self) -> Result<HashMap<String, String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT url, digest FROM embedding_docs")?;
        let mut rows = stmt.query([])?;
        let mut out = HashMap::new();
        while let Some(row) = rows.next()? {
            out.insert(row.get(0)?, row.get(1)?);
        }
        Ok(out)
    }

    /// Nearest chunks to `vector` by cosine similarity, best chunk per note.
    /// Both sides are unit vectors, so the dot product is the cosine. This is a
    /// full scan: at a few thousand chunks it costs less than an index would.
    pub fn semantic_search(
        &self,
        vector: &[f32],
        limit: u32,
        excluding: &[String],
    ) -> Result<Vec<SearchHit>> {
        if vector.is_empty() {
            return Ok(Vec::new());
        }
        let excluded: HashSet<&str> = excluding.iter().map(String::as_str).collect();
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT e.url, d.name, e.text, e.vector
             FROM embeddings e
             JOIN embedding_docs d ON d.url = e.url",
        )?;
        let mut rows = stmt.query([])?;
        let mut best: HashMap<String, (f32, String, String)> = HashMap::new();
        while let Some(row) = rows.next()? {
            let url: String = row.get(0)?;
            if excluded.contains(url.as_str()) {
                continue;
            }
            let stored: Vec<u8> = row.get(3)?;
            let score = dot(vector, &stored);
            if score <= MIN_SEMANTIC_SCORE {
                continue;
            }
            if best.get(&url).map(|(s, _, _)| *s).unwrap_or(f32::MIN) < score {
                best.insert(url, (score, row.get(1)?, row.get(2)?));
            }
        }
        let mut hits: Vec<(f32, SearchHit)> = best
            .into_iter()
            .map(|(url, (score, name, text))| {
                (
                    score,
                    SearchHit {
                        url,
                        name,
                        snippet: text,
                    },
                )
            })
            .collect();
        hits.sort_by(|a, b| b.0.total_cmp(&a.0));
        hits.truncate(limit as usize);
        Ok(hits.into_iter().map(|(_, hit)| hit).collect())
    }

    /// Notes ordered newest-first. One query, no automerge reads — the index is
    /// rewritten whenever a doc changes, so `modified` is always current.
    pub fn recent_notes(&self, limit: u32) -> Result<Vec<RecentNote>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT url, title, modified
             FROM search_docs
             WHERE kind = 'rich'
             ORDER BY modified DESC
             LIMIT ?1",
        )?;
        let mut rows = stmt.query(params![limit])?;
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            out.push(RecentNote {
                url: row.get(0)?,
                name: row.get(1)?,
                modified: row.get(2)?,
            });
        }
        Ok(out)
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
    let has_vision = kind == "file" && shapes::asset_vision(doc).is_some();
    IndexedDoc {
        url,
        kind,
        title,
        body,
        links,
        modified: shapes::doc_modified(doc),
        has_vision,
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
