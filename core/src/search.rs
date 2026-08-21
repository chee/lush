use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use anyhow::Result;
use rusqlite::{params, Connection, ErrorCode, OptionalExtension};

use crate::api::{EmbeddingChunk, IndexedNote, NotePlace, RecentNote, SearchFilter, SearchHit};
use crate::shapes;
use crate::shapes::ContextPlace;

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
    pub created: i64,
    /// File docs only: whether `@computervision` has been written yet.
    pub has_vision: bool,
    pub tags: Vec<String>,
    pub weather: Vec<String>,
    pub locations: Vec<String>,
    /// Every logline that carried a fix, in document order.
    pub places: Vec<ContextPlace>,
    pub facets: Vec<String>,
    /// The day the doc is about, `YYYY-MM-DD`, empty when it is about no day.
    pub when: String,
    /// The doc state this row was built from. An upsert whose heads match what
    /// is already stored is a no-op, so a re-crawl costs a read instead of a
    /// full FTS rewrite.
    pub heads: String,
}

/// Tags are stored as one space-delimited string wrapped in spaces, so
/// `LIKE '% cake %'` is an exact tag match rather than a prefix collision.
fn encode_tags(tags: &[String]) -> String {
    if tags.is_empty() {
        return String::new();
    }
    format!(" {} ", tags.join(" "))
}

/// Places ride as one JSON array rather than a delimited line each: a place
/// name is free text and would collide with any separator worth reading back.
fn encode_places(places: &[ContextPlace]) -> String {
    if places.is_empty() {
        return String::new();
    }
    serde_json::to_string(places).unwrap_or_default()
}

/// Open the db and touch its schema so a corrupt file surfaces here rather
/// than lazily on the first real query. Setting WAL and reading `sqlite_master`
/// both force SQLite to validate the file header.
fn open_verified(db_path: &Path) -> rusqlite::Result<Connection> {
    let conn = Connection::open(db_path)?;
    conn.busy_timeout(Duration::from_secs(10))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))?;
    Ok(conn)
}

fn remove_db_files(db_path: &Path) {
    let _ = std::fs::remove_file(db_path);
    for suffix in ["-wal", "-shm"] {
        let mut sidecar = db_path.as_os_str().to_owned();
        sidecar.push(suffix);
        let _ = std::fs::remove_file(sidecar);
    }
}

impl SearchIndex {
    pub fn open(data_dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(data_dir)?;
        let db_path = data_dir.join("search.sqlite3");
        let conn = match open_verified(&db_path) {
            Ok(conn) => conn,
            Err(err)
                if matches!(
                    err.sqlite_error_code(),
                    Some(ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase)
                ) =>
            {
                remove_db_files(&db_path);
                open_verified(&db_path)?
            }
            Err(err) => return Err(err.into()),
        };
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
            CREATE TABLE IF NOT EXISTS search_parents (
                url TEXT NOT NULL,
                parent TEXT NOT NULL,
                PRIMARY KEY (url, parent)
            );
            CREATE INDEX IF NOT EXISTS search_parents_parent
                ON search_parents(parent);
            "#,
        )?;
        let parent_pk: i64 = conn.query_row(
            "SELECT COALESCE(MAX(pk), 0) FROM pragma_table_info('search_parents') WHERE name = 'parent'",
            [],
            |row| row.get(0),
        )?;
        if parent_pk != 2 {
            conn.execute_batch(
                "DROP INDEX IF EXISTS search_parents_parent;
                 BEGIN;
                 CREATE TABLE search_parents_new (
                    url TEXT NOT NULL,
                    parent TEXT NOT NULL,
                    PRIMARY KEY (url, parent)
                 );
                 INSERT OR IGNORE INTO search_parents_new(url, parent)
                    SELECT url, parent FROM search_parents;
                 DROP TABLE search_parents;
                 ALTER TABLE search_parents_new RENAME TO search_parents;
                 CREATE INDEX search_parents_parent ON search_parents(parent);
                 COMMIT;",
            )?;
        }
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
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN tags TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN when_day TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN heads TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN created INTEGER NOT NULL DEFAULT 0",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN weather TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN locations TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN facets TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE search_docs ADD COLUMN places TEXT NOT NULL DEFAULT ''",
            [],
        );
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS search_docs_modified
                ON search_docs(modified DESC);
             CREATE INDEX IF NOT EXISTS search_docs_when
                ON search_docs(when_day) WHERE when_day <> '';",
        )?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// The `created` already stored for a doc, if any. Creation time is
    /// immutable, so a nonzero stored value spares the indexer walking the
    /// doc's whole change history again.
    pub fn stored_created(&self, url: &str) -> Option<i64> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT created FROM search_docs WHERE url = ?1",
            params![url],
            |row| row.get(0),
        )
        .optional()
        .ok()
        .flatten()
        .filter(|created| *created > 0)
    }

    pub fn upsert(&self, doc: IndexedDoc) -> Result<()> {
        let mut conn = self.conn.lock().unwrap();
        if !doc.heads.is_empty() {
            // A row written before `created` existed has to be rewritten even
            // though its heads still match, or it never gets one.
            let stored: Option<(String, i64, String, String, String, String)> = conn
                .query_row(
                    "SELECT heads, created, weather, locations, facets, places FROM search_docs WHERE url = ?1",
                    params![doc.url],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get(2)?,
                            row.get(3)?,
                            row.get(4)?,
                            row.get(5)?,
                        ))
                    },
                )
                .optional()?;
            if let Some((heads, created, weather, locations, facets, places)) = stored {
                if heads == doc.heads
                    && (created != 0 || doc.created == 0)
                    && weather == doc.weather.join("\n")
                    && locations == doc.locations.join("\n")
                    && facets == encode_tags(&doc.facets)
                    && places == encode_places(&doc.places)
                {
                    return Ok(());
                }
            }
        }
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO search_docs(url, kind, title, body, modified, has_vision, tags, when_day, heads, created, weather, locations, facets, places)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
             ON CONFLICT(url) DO UPDATE SET
                kind = excluded.kind,
                title = excluded.title,
                body = excluded.body,
                modified = excluded.modified,
                has_vision = excluded.has_vision,
                tags = excluded.tags,
                when_day = excluded.when_day,
                heads = excluded.heads,
                created = excluded.created,
                weather = excluded.weather,
                locations = excluded.locations,
                facets = excluded.facets,
                places = excluded.places",
            params![
                doc.url,
                doc.kind,
                doc.title,
                doc.body,
                doc.modified,
                doc.has_vision,
                encode_tags(&doc.tags),
                doc.when,
                doc.heads,
                doc.created,
                doc.weather.join("\n"),
                doc.locations.join("\n"),
                encode_tags(&doc.facets),
                encode_places(&doc.places)
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

    /// Replaces the whole parent map in one go. Folder membership lives in the
    /// folder docs, not the notes, so only a full tree walk knows it; the walker
    /// hands the finished edges over rather than the index guessing at them.
    pub fn set_parents(&self, parents: &[(String, String)]) -> Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM search_parents", [])?;
        {
            let mut stmt =
                tx.prepare("INSERT OR IGNORE INTO search_parents(url, parent) VALUES (?1, ?2)")?;
            for (url, parent) in parents {
                stmt.execute(params![url, parent])?;
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
        filter: &SearchFilter,
    ) -> Result<Vec<SearchHit>> {
        if vector.is_empty() {
            return Ok(Vec::new());
        }
        let excluded: HashSet<&str> = excluding.iter().map(String::as_str).collect();
        let conn = self.conn.lock().unwrap();
        let sql = FilterSql::build(filter, "e.url", 1);
        let mut stmt = conn.prepare(&format!(
            "{}SELECT e.url, n.name, e.text, e.vector
             FROM embeddings e
             JOIN embedding_docs n ON n.url = e.url
             LEFT JOIN search_docs d ON d.url = e.url{}
             WHERE 1 = 1{}",
            sql.cte, sql.join, sql.conds
        ))?;
        let mut rows = stmt.query(rusqlite::params_from_iter(sql.args.iter()))?;
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

    /// Every doc the index holds, newest first, without its text.
    pub fn indexed_notes(&self, limit: u32) -> Result<Vec<IndexedNote>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT d.url, d.title, d.kind, d.modified, d.created, d.tags, d.when_day,
                    d.weather, d.locations,
                    d.facets || ' ' || COALESCE((
                        SELECT group_concat(a.facets, ' ')
                        FROM search_links l
                        JOIN search_docs a ON a.url = l.asset_url
                        WHERE l.note_url = d.url
                    ), '')
             FROM search_docs d
             ORDER BY d.modified DESC
             LIMIT ?1",
        )?;
        let mut rows = stmt.query(params![limit])?;
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            let tags: String = row.get(5)?;
            out.push(IndexedNote {
                url: row.get(0)?,
                title: row.get(1)?,
                kind: row.get(2)?,
                modified: row.get(3)?,
                created: row.get(4)?,
                tags: tags.split_whitespace().map(str::to_string).collect(),
                when: row.get(6)?,
                weather: row
                    .get::<_, String>(7)?
                    .lines()
                    .map(str::to_string)
                    .collect(),
                locations: row
                    .get::<_, String>(8)?
                    .lines()
                    .map(str::to_string)
                    .collect(),
                has: row
                    .get::<_, String>(9)?
                    .split_whitespace()
                    .map(str::to_string)
                    .collect(),
            });
        }
        Ok(out)
    }

    /// Every logline the index has seen that carried a fix, note by note. The
    /// indexer has already read each doc once, so a map of them all costs one
    /// query rather than a walk of the whole collection.
    pub fn note_places(&self) -> Result<Vec<NotePlace>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT url, places FROM search_docs WHERE places <> '' ORDER BY url",
        )?;
        let mut rows = stmt.query([])?;
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            let url: String = row.get(0)?;
            let stored: String = row.get(1)?;
            let places: Vec<ContextPlace> = serde_json::from_str(&stored).unwrap_or_default();
            for (ordinal, place) in places.into_iter().enumerate() {
                out.push(NotePlace {
                    url: url.clone(),
                    ordinal: ordinal as u32,
                    latitude: place.lat,
                    longitude: place.lon,
                    name: place.name,
                    weather: place.weather,
                    stamped: place.ts,
                });
            }
        }
        Ok(out)
    }

    /// Everything a filter can narrow, resolved to a url set. Only worth the
    /// scan when a filter is actually set — it exists so a hit on an asset can
    /// check the notes that embed it against the same filter as the asset.
    fn filtered_urls(conn: &Connection, filter: &SearchFilter) -> Result<Option<HashSet<String>>> {
        let sql = FilterSql::build(filter, "d.url", 1);
        if sql.is_empty() {
            return Ok(None);
        }
        let mut stmt = conn.prepare(&format!(
            "{}SELECT d.url FROM search_docs d{} WHERE 1 = 1{}",
            sql.cte, sql.join, sql.conds
        ))?;
        let mut rows = stmt.query(rusqlite::params_from_iter(sql.args.iter()))?;
        let mut out = HashSet::new();
        while let Some(row) = rows.next()? {
            out.insert(row.get(0)?);
        }
        Ok(Some(out))
    }

    pub fn search(&self, query: &str, filter: &SearchFilter) -> Result<Vec<SearchHit>> {
        let Some(parsed) = parse_query(query) else {
            return Ok(Vec::new());
        };
        let term = parsed.snippet_term(query).to_string();
        let conn = self.conn.lock().unwrap();
        let allowed = Self::filtered_urls(&conn, filter)?;
        // Narrowing has to happen inside the query: the limit is applied by
        // rank, so a filter run afterwards would keep only the survivors of the
        // top 200 rather than the top 200 of the folder.
        let sql = FilterSql::build(filter, "f.url", 2);
        let mut stmt = conn.prepare(&format!(
            "{}SELECT f.url, f.kind, f.title, f.body
             FROM (
                SELECT url, kind, title, body, rank AS ranking
                FROM search_docs_fts
                WHERE search_docs_fts MATCH ?1
             ) f
             LEFT JOIN search_docs d ON d.url = f.url{}
             WHERE 1 = 1{}
             ORDER BY f.ranking
             LIMIT 200",
            sql.cte, sql.join, sql.conds
        ))?;
        let mut args: Vec<&dyn rusqlite::ToSql> = vec![&parsed.fts];
        args.extend(sql.args.iter().map(|a| a as &dyn rusqlite::ToSql));
        let mut rows = stmt.query(args.as_slice())?;
        let mut hits = Vec::new();
        let mut seen_notes = std::collections::HashSet::new();
        while let Some(row) = rows.next()? {
            let url: String = row.get(0)?;
            let kind: String = row.get(1)?;
            let title: String = row.get(2)?;
            let body: String = row.get(3)?;
            if !parsed.matches(&title, &body) {
                continue;
            }
            if kind == "rich" {
                if seen_notes.insert(url.clone()) {
                    hits.push(SearchHit {
                        url,
                        name: title.clone(),
                        snippet: snippet(&body, &title, &term),
                    });
                }
            } else if kind == "file" {
                if seen_notes.insert(url.clone()) {
                    hits.push(SearchHit {
                        url: url.clone(),
                        name: title.clone(),
                        snippet: snippet(&body, &title, &term),
                    });
                }
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
                    if allowed.as_ref().is_some_and(|set| !set.contains(&note_url)) {
                        continue;
                    }
                    if seen_notes.insert(note_url.clone()) {
                        hits.push(SearchHit {
                            url: note_url,
                            name: note_name,
                            snippet: snippet(&body, &title, &term),
                        });
                    }
                }
            }
        }
        Ok(hits)
    }
}

pub fn indexed_doc(
    url: String,
    doc: &automerge::Automerge,
    known_created: Option<i64>,
) -> IndexedDoc {
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
    let context = shapes::context_index(doc);
    let mut heads: Vec<String> = doc.get_heads().iter().map(ToString::to_string).collect();
    heads.sort();
    IndexedDoc {
        url,
        kind,
        title,
        body,
        links,
        modified: shapes::doc_modified(doc),
        created: known_created
            .filter(|stamp| *stamp > 0)
            .unwrap_or_else(|| shapes::doc_created(doc)),
        has_vision,
        tags: shapes::doc_tags(doc),
        weather: context.weather,
        locations: context.locations,
        places: context.places,
        facets: shapes::doc_facets(doc),
        when: shapes::doc_when(doc),
        heads: heads.join(","),
    }
}

/// The SQL for a `SearchFilter`, split into the pieces a query needs to splice
/// in. `first` is the number the caller's own placeholders have already used up.
struct FilterSql {
    cte: String,
    join: String,
    conds: String,
    args: Vec<String>,
}

impl FilterSql {
    /// `url_column` is whatever the query calls the doc url, so the scope join
    /// can attach to the fts table, `embeddings`, or `search_docs` alike.
    fn build(filter: &SearchFilter, url_column: &str, first: usize) -> Self {
        let mut sql = FilterSql {
            cte: String::new(),
            join: String::new(),
            conds: String::new(),
            args: Vec::new(),
        };
        let mut index = first;
        if let Some(scope) = filter.scope.as_deref().filter(|s| !s.is_empty()) {
            sql.cte = format!(
                "WITH RECURSIVE scope(url) AS (
                    SELECT ?{index}
                    UNION
                    SELECT p.url FROM search_parents p JOIN scope s ON p.parent = s.url
                 ) "
            );
            sql.join = format!(" JOIN scope ON scope.url = {url_column} ");
            sql.args.push(scope.to_string());
            index += 1;
        }
        for tag in filter.tags.iter().filter(|t| !t.is_empty()) {
            sql.conds
                .push_str(&format!(" AND d.tags LIKE ?{index} ESCAPE '\\' "));
            sql.args.push(format!("% {} %", escape_like(tag)));
            index += 1;
        }
        if let Some(from) = filter.when_from.as_deref().filter(|s| !s.is_empty()) {
            sql.conds.push_str(&format!(
                " AND d.when_day <> '' AND d.when_day >= ?{index} "
            ));
            sql.args.push(from.to_string());
            index += 1;
        }
        if let Some(to) = filter.when_to.as_deref().filter(|s| !s.is_empty()) {
            sql.conds.push_str(&format!(
                " AND d.when_day <> '' AND d.when_day <= ?{index} "
            ));
            sql.args.push(to.to_string());
        }
        sql
    }

    fn is_empty(&self) -> bool {
        self.args.is_empty()
    }
}

fn escape_like(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

/// A query is loose words plus any double-quoted phrases. Loose words match by
/// prefix; a phrase must appear verbatim, so the FTS match is only a
/// prefilter — `phrases` is checked against the text itself afterwards.
struct ParsedQuery {
    fts: String,
    phrases: Vec<String>,
}

fn word(term: &str) -> String {
    term.chars().filter(|c| c.is_alphanumeric()).collect()
}

fn parse_query(query: &str) -> Option<ParsedQuery> {
    let mut terms: Vec<String> = Vec::new();
    let mut phrases: Vec<String> = Vec::new();
    for (index, part) in query.split('"').enumerate() {
        if index % 2 == 1 {
            let words: Vec<String> = part
                .split_whitespace()
                .map(word)
                .filter(|w| !w.is_empty())
                .collect();
            if words.is_empty() {
                continue;
            }
            phrases.push(part.trim().to_lowercase());
            terms.push(format!("\"{}\"", words.join(" ")));
        } else {
            terms.extend(part.split_whitespace().filter_map(|term| {
                let cleaned = word(term);
                (!cleaned.is_empty()).then(|| format!("\"{cleaned}\"*"))
            }));
        }
    }
    if terms.is_empty() {
        None
    } else {
        Some(ParsedQuery {
            fts: terms.join(" "),
            phrases,
        })
    }
}

impl ParsedQuery {
    fn matches(&self, title: &str, body: &str) -> bool {
        if self.phrases.is_empty() {
            return true;
        }
        let title = title.to_lowercase();
        let body = body.to_lowercase();
        self.phrases
            .iter()
            .all(|phrase| body.contains(phrase) || title.contains(phrase))
    }

    fn snippet_term<'a>(&'a self, query: &'a str) -> &'a str {
        self.phrases.first().map(String::as_str).unwrap_or(query)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loose_words_match_by_prefix() {
        let parsed = parse_query("blue hat").unwrap();
        assert_eq!(parsed.fts, "\"blue\"* \"hat\"*");
        assert!(parsed.phrases.is_empty());
        assert!(parsed.matches("anything", "at all"));
    }

    #[test]
    fn quoted_text_must_appear_verbatim() {
        let parsed = parse_query("\"blue hat\"").unwrap();
        assert_eq!(parsed.fts, "\"blue hat\"");
        assert!(parsed.matches("note", "she wore a Blue Hat"));
        assert!(!parsed.matches("note", "a blue and green hat"));
    }

    #[test]
    fn quotes_mix_with_loose_words() {
        let parsed = parse_query("notes on \"blue hat\"").unwrap();
        assert_eq!(parsed.fts, "\"notes\"* \"on\"* \"blue hat\"");
        assert_eq!(parsed.snippet_term("notes on \"blue hat\""), "blue hat");
    }

    #[test]
    fn punctuation_only_query_matches_nothing() {
        assert!(parse_query("\"\" ...").is_none());
    }

    fn indexed(url: &str, title: &str, tags: &[&str], when: &str) -> IndexedDoc {
        IndexedDoc {
            url: url.into(),
            kind: "rich".into(),
            title: title.into(),
            body: "cake recipe".into(),
            links: Vec::new(),
            modified: 0,
            created: 0,
            has_vision: false,
            tags: tags.iter().map(|t| t.to_string()).collect(),
            weather: Vec::new(),
            locations: Vec::new(),
            places: Vec::new(),
            facets: Vec::new(),
            when: when.into(),
            heads: String::new(),
        }
    }

    fn urls(hits: Vec<SearchHit>) -> Vec<String> {
        let mut out: Vec<String> = hits.into_iter().map(|h| h.url).collect();
        out.sort();
        out
    }

    fn fixture() -> SearchIndex {
        let dir =
            std::env::temp_dir().join(format!("lush-search-{:?}", std::thread::current().id()));
        let _ = std::fs::remove_dir_all(&dir);
        let index = SearchIndex::open(&dir).unwrap();
        index
            .upsert(indexed("note", "cake", &["baking"], "2026-08-09"))
            .unwrap();
        index
            .upsert(indexed("deep", "cake", &["baking", "party"], "2026-09-01"))
            .unwrap();
        index.upsert(indexed("outside", "cake", &[], "")).unwrap();
        index
            .set_parents(&[
                ("note".into(), "work".into()),
                ("note".into(), "home".into()),
                ("sub".into(), "work".into()),
                ("deep".into(), "sub".into()),
                ("outside".into(), "home".into()),
            ])
            .unwrap();
        index
    }

    #[test]
    fn scope_reaches_the_whole_subtree() {
        let index = fixture();
        let filter = SearchFilter {
            scope: Some("work".into()),
            ..Default::default()
        };
        assert_eq!(
            urls(index.search("cake", &filter).unwrap()),
            ["deep", "note"]
        );
    }

    #[test]
    fn scope_keeps_notes_with_multiple_parents() {
        let index = fixture();
        let filter = SearchFilter {
            scope: Some("home".into()),
            ..Default::default()
        };
        assert_eq!(
            urls(index.search("cake", &filter).unwrap()),
            ["note", "outside"]
        );
    }

    #[test]
    fn an_empty_filter_keeps_everything() {
        let index = fixture();
        let all = urls(index.search("cake", &SearchFilter::default()).unwrap());
        assert_eq!(all, ["deep", "note", "outside"]);
    }

    #[test]
    fn tags_are_matched_whole_and_together() {
        let index = fixture();
        let one = SearchFilter {
            tags: vec!["bak".into()],
            ..Default::default()
        };
        assert!(index.search("cake", &one).unwrap().is_empty());
        let both = SearchFilter {
            tags: vec!["baking".into(), "party".into()],
            ..Default::default()
        };
        assert_eq!(urls(index.search("cake", &both).unwrap()), ["deep"]);
    }

    #[test]
    fn when_bounds_are_inclusive_and_skip_dayless_docs() {
        let index = fixture();
        let filter = SearchFilter {
            when_from: Some("2026-08-09".into()),
            when_to: Some("2026-08-31".into()),
            ..Default::default()
        };
        assert_eq!(urls(index.search("cake", &filter).unwrap()), ["note"]);
    }

    #[test]
    fn a_file_that_is_not_a_database_is_rebuilt() {
        let dir = std::env::temp_dir().join("lush-search-notadb");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("search.sqlite3"), "garbage".repeat(64)).unwrap();
        let index = SearchIndex::open(&dir).unwrap();
        index.upsert(indexed("note", "cake", &[], "")).unwrap();
        assert_eq!(
            urls(index.search("cake", &SearchFilter::default()).unwrap()),
            ["note"]
        );
    }

    #[test]
    fn placed_loglines_come_back_note_by_note() {
        let index = fixture();
        let mut doc = indexed("placed", "trip", &[], "");
        doc.places = vec![
            ContextPlace {
                lat: 55.8642,
                lon: -4.2518,
                name: "Glasgow".into(),
                weather: "Rain".into(),
                ts: "2026-03-04T09:00:00Z".into(),
            },
            ContextPlace {
                lat: 51.5072,
                lon: -0.1276,
                name: String::new(),
                weather: String::new(),
                ts: String::new(),
            },
        ];
        index.upsert(doc).unwrap();

        let places = index.note_places().unwrap();
        assert_eq!(places.len(), 2);
        assert_eq!(places[0].url, "placed");
        assert_eq!(places[0].ordinal, 0);
        assert_eq!(places[0].name, "Glasgow");
        assert_eq!(places[0].stamped, "2026-03-04T09:00:00Z");
        assert_eq!(places[1].ordinal, 1);
        assert!((places[1].longitude + 0.1276).abs() < 0.0001);
    }

    /// A row written before the column existed keeps its heads, so only the
    /// places comparison can tell the upsert it is out of date.
    #[test]
    fn placeless_note_is_rewritten_when_its_loglines_arrive() {
        let index = fixture();
        let mut doc = indexed("late", "trip", &[], "");
        doc.heads = "abc".into();
        index.upsert(doc.clone()).unwrap();
        assert!(index.note_places().unwrap().is_empty());

        doc.places = vec![ContextPlace {
            lat: 55.8642,
            lon: -4.2518,
            name: "Glasgow".into(),
            weather: String::new(),
            ts: String::new(),
        }];
        index.upsert(doc).unwrap();
        assert_eq!(index.note_places().unwrap().len(), 1);
    }

    #[test]
    fn stored_created_returns_only_nonzero_values() {
        let dir = std::env::temp_dir().join(format!(
            "lush-search-created-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let index = SearchIndex::open(&dir).unwrap();
        assert_eq!(index.stored_created("missing"), None);
        index.upsert(indexed("dateless", "cake", &[], "")).unwrap();
        assert_eq!(index.stored_created("dateless"), None);
        let mut doc = indexed("note", "cake", &[], "");
        doc.created = 123;
        index.upsert(doc).unwrap();
        assert_eq!(index.stored_created("note"), Some(123));
    }

    #[test]
    fn indexed_doc_reuses_a_known_created() {
        use automerge::transaction::{CommitOptions, Transactable};
        let mut doc = automerge::Automerge::new();
        doc.transact_with(
            |_| CommitOptions::default().with_time(111),
            |t| t.put(automerge::ROOT, "title", "hi"),
        )
        .unwrap();
        assert_eq!(indexed_doc("u".into(), &doc, None).created, 111);
        assert_eq!(indexed_doc("u".into(), &doc, Some(42)).created, 42);
        assert_eq!(indexed_doc("u".into(), &doc, Some(0)).created, 111);
    }

    #[test]
    fn single_parent_schema_is_migrated() {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "lush-search-parent-migration-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("search.sqlite3");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE search_parents (
                url TEXT PRIMARY KEY NOT NULL,
                parent TEXT NOT NULL
             );
             INSERT INTO search_parents(url, parent) VALUES ('note', 'work');",
        )
        .unwrap();
        drop(conn);
        let index = SearchIndex::open(&dir).unwrap();
        index
            .set_parents(&[
                ("note".into(), "work".into()),
                ("note".into(), "home".into()),
            ])
            .unwrap();
        let conn = index.conn.lock().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT count(*) FROM search_parents WHERE url = 'note'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 2);
    }
}
