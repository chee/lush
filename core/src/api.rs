use std::{collections::HashMap, path::PathBuf, str::FromStr, sync::Arc, time::Duration};

use automerge::ChangeHash;
use tokio::runtime::Runtime;

use crate::{
    repo::{DocId, Repo, RepoEvent, DEFAULT_SERVER},
    search::{self, SearchIndex},
    shapes,
};

fn synthesize_kind(kind: &str, lush: Option<&str>) -> String {
    if kind == "file" && lush == Some("script") {
        "lush:script".into()
    } else {
        kind.into()
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("{msg}")]
    General { msg: String },
}

impl From<anyhow::Error> for CoreError {
    fn from(e: anyhow::Error) -> Self {
        CoreError::General {
            msg: format!("{e:#}"),
        }
    }
}

/// The pinned automerge fragments branch can panic on some change graphs
/// (change_graph.rs fragment-level assertions). Turn panics in write paths
/// into errors so a single bad doc can't abort a batch operation.
fn guarded<T>(f: impl FnOnce() -> Result<T, CoreError>) -> Result<T, CoreError> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|_| {
        Err(CoreError::General {
            msg: "internal error (automerge panic); the change was not saved".into(),
        })
    })
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NoteInfo {
    pub url: String,
    pub name: String,
    pub kind: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NoteSpansSnapshot {
    pub spans_json: String,
    pub heads: Vec<String>,
}

fn encode_heads(heads: Vec<ChangeHash>) -> Vec<String> {
    heads.into_iter().map(|h| h.to_string()).collect()
}

fn decode_heads(heads: Vec<String>) -> Result<Vec<ChangeHash>, CoreError> {
    heads
        .into_iter()
        .map(|head| {
            ChangeHash::from_str(&head).map_err(|e| CoreError::General {
                msg: format!("invalid change head {head}: {e}"),
            })
        })
        .collect()
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AssetInfo {
    pub name: String,
    pub mime_type: String,
    pub extension: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchHit {
    pub url: String,
    pub name: String,
    pub snippet: String,
}

/// One embedded passage of a note. `vector` must be unit length — the index
/// compares with a plain dot product.
#[derive(Debug, Clone, uniffi::Record)]
pub struct EmbeddingChunk {
    pub text: String,
    pub vector: Vec<f32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RecentNote {
    pub url: String,
    pub name: String,
    /// Unix seconds; 0 when the note has not been indexed yet.
    pub modified: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AssetVision {
    pub description: String,
    pub ocr: String,
}

#[uniffi::export(callback_interface)]
pub trait CoreDelegate: Send + Sync {
    fn on_doc_changed(&self, url: String);
    fn on_connection_changed(&self, connected: bool);
    fn on_sync_event(&self, message: String);
}

#[derive(uniffi::Object)]
pub struct Core {
    runtime: Runtime,
    repo: Arc<Repo>,
    index: Arc<SearchIndex>,
    folder: std::sync::Mutex<Option<DocId>>,
}

const OPEN_TIMEOUT: Duration = Duration::from_secs(60);

impl Core {
    fn start_index_updates(self: &Arc<Self>) {
        let mut events = self.repo.subscribe();
        let repo = self.repo.clone();
        let index = self.index.clone();
        self.runtime.spawn(async move {
            loop {
                match events.recv().await {
                    Ok(RepoEvent::DocChanged(id)) => {
                        tokio::spawn(index_doc(repo.clone(), index.clone(), id));
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!("index missed {n} events");
                    }
                    _ => break,
                }
            }
        });
    }

    fn reindex_doc(&self, id: DocId) {
        let repo = self.repo.clone();
        let index = self.index.clone();
        self.runtime
            .block_on(async move { index_doc(repo, index, id).await });
    }

    /// Run work on the core's runtime and hand the caller a future instead of
    /// blocking its thread. Awaiting a JoinHandle needs no ambient runtime, so
    /// UniFFI can drive this from Swift's executor while the work stays here.
    /// A fan-out of reads then costs futures rather than threads.
    async fn run<F, T>(&self, fut: F) -> Result<T, CoreError>
    where
        F: std::future::Future<Output = T> + Send + 'static,
        T: Send + 'static,
    {
        self.runtime
            .spawn(fut)
            .await
            .map_err(|e| CoreError::General {
                msg: format!("core task failed: {e}"),
            })
    }
}

async fn index_doc(repo: Arc<Repo>, index: Arc<SearchIndex>, id: DocId) {
    let url = id.to_url();
    let indexed = repo
        .read_doc(id, |doc| Ok(search::indexed_doc(url.clone(), doc)))
        .await;
    match indexed {
        Ok(doc) if doc.kind == "rich" || doc.kind == "file" => {
            if let Err(e) = index.upsert(doc) {
                tracing::warn!(error = %e, "search index update failed");
            }
        }
        Ok(_) => {
            if let Err(e) = index.remove(&url) {
                tracing::warn!(error = %e, "search index remove failed");
            }
        }
        Err(e) => tracing::warn!(error = %e, "search index read failed"),
    }
}

#[uniffi::export]
impl Core {
    #[uniffi::constructor]
    pub fn new(data_dir: String, server_url: Option<String>) -> Result<Arc<Self>, CoreError> {
        let runtime = Runtime::new().map_err(|e| CoreError::General {
            msg: format!("tokio runtime: {e}"),
        })?;
        let server = server_url.unwrap_or_else(|| DEFAULT_SERVER.to_string());
        let data_dir = PathBuf::from(data_dir);
        let index = Arc::new(SearchIndex::open(&data_dir)?);
        let repo = runtime.block_on(Repo::start(data_dir, server))?;
        let core = Arc::new(Core {
            runtime,
            repo,
            index,
            folder: std::sync::Mutex::new(None),
        });
        core.start_index_updates();
        Ok(core)
    }

    pub fn set_delegate(&self, delegate: Box<dyn CoreDelegate>) {
        let mut events = self.repo.subscribe();
        self.runtime.spawn(async move {
            loop {
                match events.recv().await {
                    Ok(RepoEvent::DocChanged(id)) => delegate.on_doc_changed(id.to_url()),
                    Ok(RepoEvent::Connected) => delegate.on_connection_changed(true),
                    Ok(RepoEvent::Disconnected) => delegate.on_connection_changed(false),
                    Ok(RepoEvent::SyncEvent(msg)) => delegate.on_sync_event(msg),
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!("delegate missed {n} events");
                        delegate.on_sync_event(format!("[warn] delegate missed {n} events — some updates may be delayed"));
                    }
                    Err(_) => break,
                }
            }
        });
    }

    pub fn resync_doc(&self, url: String) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        let id = DocId::from_url(&url)?;
        self.runtime.block_on(async move {
            repo.drop_doc(id).await;
            repo.ensure_doc(id).await
        })?;
        Ok(())
    }

    pub fn doc_change_count(&self, url: String) -> u32 {
        let Ok(id) = DocId::from_url(&url) else { return 0 };
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| {
                Ok(doc.get_changes(&[]).len() as u32)
            }))
            .unwrap_or(0)
    }

    pub fn is_connected(&self) -> bool {
        self.repo.is_connected()
    }

    /// Port of the loopback subduction listener the core hosts, if it bound.
    /// Webviews connect here to sync against the core's own storage.
    pub fn local_server_port(&self) -> Option<u16> {
        self.repo.local_server_port()
    }

    /// Open an existing folder doc (waiting for it to arrive if needed) or
    /// create a fresh one. Returns the folder's automerge URL.
    pub fn ensure_folder(&self, existing_url: Option<String>) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let id = self.runtime.block_on(async move {
            match existing_url {
                Some(url) => {
                    let id = DocId::from_url(&url)?;
                    repo.ensure_doc(id).await?;
                    Ok(id)
                }
                None => {
                    repo.create_doc(|doc| shapes::init_folder(doc, "Notes"))
                        .await
                }
            }
        })?;
        *self.folder.lock().unwrap() = Some(id);
        Ok(id.to_url())
    }

    /// Set the active folder immediately from a known URL, then load the doc
    /// from local storage in the background. Returns before any I/O completes,
    /// so the UI can be ready immediately.
    pub fn start_folder_url(&self, url: String) -> Result<(), CoreError> {
        let id = DocId::from_url(&url)?;
        *self.folder.lock().unwrap() = Some(id);
        let repo = self.repo.clone();
        self.runtime.spawn(async move {
            let _ = repo.ensure_doc(id).await;
        });
        Ok(())
    }

    pub fn folder_url(&self) -> Option<String> {
        self.folder.lock().unwrap().map(DocId::to_url)
    }

    pub async fn folder_title(&self) -> String {
        let Some(id) = *self.folder.lock().unwrap() else {
            return String::new();
        };
        let repo = self.repo.clone();
        self.run(async move { repo.read_doc(id, |doc| Ok(shapes::doc_title(doc))).await })
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default()
    }

    pub async fn list_notes(&self) -> Vec<NoteInfo> {
        let Some(id) = *self.folder.lock().unwrap() else {
            return Vec::new();
        };
        let repo = self.repo.clone();
        self.run(async move { repo.read_doc(id, |doc| shapes::folder_entries(doc)).await })
            .await
            .ok()
            .and_then(Result::ok)
            .map(|entries| {
                entries
                    .into_iter()
                    .filter_map(|e| {
                        let kind = synthesize_kind(&e.kind, e.lush.as_deref());
                        if kind == "rich" || kind == "folder" || kind == "lush:script" {
                            Some(NoteInfo {
                                url: e.url,
                                name: e.name,
                                kind,
                            })
                        } else {
                            None
                        }
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Entries of any folder doc we hold locally (no waiting, no network).
    pub async fn folder_entries_of(&self, url: String) -> Vec<NoteInfo> {
        let Ok(id) = DocId::from_url(&url) else {
            return Vec::new();
        };
        let repo = self.repo.clone();
        self.run(async move { repo.read_doc(id, |doc| shapes::folder_entries(doc)).await })
            .await
            .ok()
            .and_then(Result::ok)
            .map(|entries| {
                entries
                    .into_iter()
                    .map(|e| {
                        let kind = synthesize_kind(&e.kind, e.lush.as_deref());
                        NoteInfo {
                            url: e.url,
                            name: e.name,
                            kind,
                        }
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Bytes of the first embedded image in a note, if the asset is already
    /// held locally. Returns None without any network I/O.
    pub async fn note_thumbnail_bytes(&self, url: String) -> Option<Vec<u8>> {
        let id = DocId::from_url(&url).ok()?;
        let repo = self.repo.clone();
        self.run(async move {
            let embed_urls = repo
                .read_doc(id, |doc| Ok(shapes::embed_urls(doc)))
                .await
                .ok()?;
            let asset_id = DocId::from_url(&embed_urls.into_iter().next()?).ok()?;
            repo.read_doc(asset_id, |doc| {
                shapes::file_bytes(doc).ok_or_else(|| anyhow::anyhow!("no bytes"))
            })
            .await
            .ok()
        })
        .await
        .ok()
        .flatten()
    }

    /// Current automerge heads for any doc we hold locally. Returns an empty
    /// vec if the doc isn't tracked or has no changes.
    pub async fn doc_heads(&self, url: String) -> Vec<String> {
        let Ok(id) = DocId::from_url(&url) else {
            return Vec::new();
        };
        let repo = self.repo.clone();
        self.run(async move {
            repo.read_doc(id, |doc| Ok(encode_heads(doc.get_heads())))
                .await
        })
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or_default()
    }

    /// Move an entry from one folder doc to another, refusing cycles.
    pub fn move_entry(
        &self,
        from_folder: String,
        to_folder: String,
        url: String,
    ) -> Result<(), CoreError> {
        if from_folder == to_folder || to_folder == url {
            return Ok(());
        }
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let from = DocId::from_url(&from_folder)?;
            let to = DocId::from_url(&to_folder)?;
            let moved = DocId::from_url(&url)?;
            // reject moving a folder into its own subtree
            let mut stack = vec![moved];
            let mut visited = std::collections::HashSet::new();
            while let Some(folder) = stack.pop() {
                if !visited.insert(folder) {
                    continue;
                }
                if folder == to {
                    anyhow::bail!("can't move a folder inside itself");
                }
                if let Ok(entries) = repo.read_doc(folder, |d| shapes::folder_entries(d)).await {
                    for entry in entries.iter().filter(|e| e.kind == "folder") {
                        if let Ok(id) = DocId::from_url(&entry.url) {
                            stack.push(id);
                        }
                    }
                }
            }
            let link = repo
                .read_doc(from, |d| {
                    Ok(shapes::folder_entries(d)?
                        .into_iter()
                        .find(|e| e.url == url))
                })
                .await?
                .ok_or_else(|| anyhow::anyhow!("entry not found in source folder"))?;
            repo.change_doc(to, |d| shapes::add_folder_entry(d, &link))
                .await?;
            repo.change_doc(from, |d| shapes::remove_folder_entry(d, &url))
                .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    /// Remove an entry from a specific folder doc.
    pub fn remove_entry(&self, folder_url: String, url: String) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let folder = DocId::from_url(&folder_url)?;
            repo.change_doc(folder, |doc| shapes::remove_folder_entry(doc, &url))
                .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    /// Rename a doc and its entry inside a specific folder doc.
    pub fn rename_entry(
        &self,
        folder_url: String,
        url: String,
        title: String,
    ) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        let reindex_url = url.clone();
        self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.change_doc(id, |doc| shapes::set_note_title(doc, &title))
                .await?;
            let folder = DocId::from_url(&folder_url)?;
            repo.change_doc(folder, |doc| shapes::rename_folder_entry(doc, &url, &title))
                .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        self.reindex_doc(DocId::from_url(&reindex_url)?);
        Ok(())
    }

    /// Create a folder doc inside the current folder.
    pub fn create_subfolder(&self, title: String) -> Result<String, CoreError> {
        let folder = self
            .folder
            .lock()
            .unwrap()
            .ok_or_else(|| CoreError::General {
                msg: "no folder open".into(),
            })?;
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let sub = repo
                .create_doc(|doc| shapes::init_folder(doc, &title))
                .await?;
            repo.change_doc(folder, |doc| {
                shapes::add_folder_entry(
                    doc,
                    &shapes::DocLink {
                        name: title.clone(),
                        kind: "folder".into(),
                        url: sub.to_url(),
                        lush: None,
                    },
                )
            })
            .await?;
            Ok::<_, anyhow::Error>(sub.to_url())
        })?;
        Ok(url)
    }

    pub fn create_note(&self, title: String) -> Result<String, CoreError> {
        let folder = self
            .folder
            .lock()
            .unwrap()
            .ok_or_else(|| CoreError::General {
                msg: "no folder open".into(),
            })?;
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let note = repo
                .create_doc(|doc| shapes::init_rich_note(doc, &title))
                .await?;
            repo.change_doc(folder, |doc| {
                shapes::add_folder_entry(
                    doc,
                    &shapes::DocLink {
                        name: title.clone(),
                        kind: "rich".into(),
                        url: note.to_url(),
                        lush: None,
                    },
                )
            })
            .await?;
            Ok::<_, anyhow::Error>(note.to_url())
        })?;
        self.reindex_doc(DocId::from_url(&url)?);
        Ok(url)
    }

    /// Create a note doc immediately without waiting for the folder to be in
    /// memory. The caller is responsible for linking it to a folder separately.
    pub fn create_note_doc(&self, title: String) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let note = repo
                .create_doc(|doc| shapes::init_rich_note(doc, &title))
                .await?;
            Ok::<_, anyhow::Error>(note.to_url())
        })?;
        self.reindex_doc(DocId::from_url(&url)?);
        Ok(url)
    }

    /// Link a note into the current folder. The folder doc is loaded from
    /// local storage on demand if not already in memory.
    pub fn link_note_to_folder(&self, note_url: String, title: String) -> Result<(), CoreError> {
        let folder = self
            .folder
            .lock()
            .unwrap()
            .ok_or_else(|| CoreError::General {
                msg: "no folder open".into(),
            })?;
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            repo.change_doc(folder, |doc| {
                shapes::add_folder_entry(
                    doc,
                    &shapes::DocLink {
                        name: title,
                        kind: "rich".into(),
                        url: note_url,
                        lush: None,
                    },
                )
            })
            .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    pub fn delete_note(&self, url: String) -> Result<(), CoreError> {
        let folder = self
            .folder
            .lock()
            .unwrap()
            .ok_or_else(|| CoreError::General {
                msg: "no folder open".into(),
            })?;
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            repo.change_doc(folder, |doc| shapes::remove_folder_entry(doc, &url))
                .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    pub fn rename_note(&self, url: String, title: String) -> Result<(), CoreError> {
        let folder = self
            .folder
            .lock()
            .unwrap()
            .ok_or_else(|| CoreError::General {
                msg: "no folder open".into(),
            })?;
        let repo = self.repo.clone();
        let reindex_url = url.clone();
        self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.change_doc(id, |doc| shapes::set_note_title(doc, &title))
                .await?;
            repo.change_doc(folder, |doc| shapes::rename_folder_entry(doc, &url, &title))
                .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        self.reindex_doc(DocId::from_url(&reindex_url)?);
        Ok(())
    }

    /// Start tracking + syncing a note. Returns once the doc is available
    /// locally (immediately for docs we already have).
    pub async fn open_note(&self, url: String) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        let index = self.index.clone();
        let id = DocId::from_url(&url)?;
        self.run(async move {
            repo.ensure_doc(id).await?;
            if repo.wait_for_doc(id, OPEN_TIMEOUT).await {
                repo.change_doc(id, |doc| shapes::normalize_strings(doc))
                    .await?;
            }
            index_doc(repo, index, id).await;
            Ok::<_, anyhow::Error>(())
        })
        .await??;
        Ok(())
    }

    /// Start tracking + syncing docs without waiting for them to arrive,
    /// recursing into subfolders. Once a doc lands, its legacy scalar
    /// strings are normalized to Text.
    pub fn prefetch_notes(&self, urls: Vec<String>) {
        let repo = self.repo.clone();
        let index = self.index.clone();
        self.runtime.spawn(async move {
            let mut visited = std::collections::HashSet::new();
            let mut queue: Vec<String> = urls;
            while let Some(url) = queue.pop() {
                let Ok(id) = DocId::from_url(&url) else {
                    continue;
                };
                if !visited.insert(id) || visited.len() > 500 {
                    continue;
                }
                if repo.ensure_doc(id).await.is_err() {
                    continue;
                }
                if !repo.wait_for_doc(id, Duration::from_secs(30)).await {
                    continue;
                }
                let _ = repo
                    .change_doc(id, |doc| shapes::normalize_strings(doc))
                    .await;
                tokio::spawn(index_doc(repo.clone(), index.clone(), id));
                if let Ok(entries) = repo.read_doc(id, |doc| shapes::folder_entries(doc)).await {
                    for entry in entries {
                        queue.push(entry.url);
                    }
                }
                if let Ok(embeds) = repo.read_doc(id, |doc| Ok(shapes::embed_urls(doc))).await {
                    queue.extend(embeds);
                }
            }
        });
    }

    /// Full-text search across every locally indexed note. The index is local
    /// to this device and is updated as prefetched docs land or change.
    pub fn search_notes(&self, query: String) -> Vec<SearchHit> {
        let query = query.trim().to_string();
        if query.is_empty() {
            return Vec::new();
        }
        self.index.search(&query).unwrap_or_default()
    }

    pub async fn note_preview(&self, url: String) -> String {
        let Ok(id) = DocId::from_url(&url) else {
            return String::new();
        };
        let repo = self.repo.clone();
        self.run(async move { repo.read_doc(id, |doc| Ok(shapes::note_preview(doc))).await })
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default()
    }

    /// Store binary data as a patchwork UnixFileEntry doc; returns its URL.
    pub fn create_asset(
        &self,
        name: String,
        extension: String,
        mime_type: String,
        data: Vec<u8>,
    ) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let id = repo
                .create_doc(|doc| shapes::init_file_doc(doc, &name, &extension, &mime_type, data))
                .await?;
            Ok::<_, anyhow::Error>(id.to_url())
        })?;
        self.reindex_doc(DocId::from_url(&url)?);
        Ok(url)
    }

    /// Write Vision OCR + description onto a UnixFileEntry doc.
    pub fn update_asset_vision(
        &self,
        url: String,
        description: String,
        ocr: String,
    ) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        let reindex_url = url.clone();
        self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.ensure_doc(id).await?;
            if !repo.wait_for_doc(id, OPEN_TIMEOUT).await {
                anyhow::bail!("asset not found");
            }
            repo.change_doc(id, |doc| {
                shapes::set_vision_metadata(doc, &description, &ocr)
            })
            .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        self.reindex_doc(DocId::from_url(&reindex_url)?);
        Ok(())
    }

    pub fn asset_info(&self, url: String) -> Option<AssetInfo> {
        let id = DocId::from_url(&url).ok()?;
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| {
                Ok(AssetInfo {
                    name: shapes::doc_field(doc, "name"),
                    mime_type: shapes::doc_field(doc, "mimeType"),
                    extension: shapes::doc_field(doc, "extension"),
                })
            }))
            .ok()
    }

    pub fn asset_vision(&self, url: String) -> Option<AssetVision> {
        let id = DocId::from_url(&url).ok()?;
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| Ok(shapes::asset_vision(doc))))
            .ok()
            .flatten()
            .map(|(description, ocr)| AssetVision { description, ocr })
    }

    pub async fn asset_bytes(&self, url: String) -> Result<Vec<u8>, CoreError> {
        let repo = self.repo.clone();
        let bytes = self
            .run(async move {
                let id = DocId::from_url(&url)?;
                repo.ensure_doc(id).await?;
                if !repo.wait_for_doc(id, OPEN_TIMEOUT).await {
                    anyhow::bail!("asset not found locally or on the server");
                }
                repo.read_doc(id, |doc| {
                    shapes::file_bytes(doc)
                        .ok_or_else(|| anyhow::anyhow!("doc has no binary content"))
                })
                .await
            })
            .await??;
        Ok(bytes)
    }

    pub async fn note_title(&self, url: String) -> String {
        let Ok(id) = DocId::from_url(&url) else {
            return String::new();
        };
        let repo = self.repo.clone();
        self.run(async move { repo.read_doc(id, |doc| Ok(shapes::doc_title(doc))).await })
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default()
    }

    pub async fn note_spans_json(&self, url: String) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let json = self
            .run(async move {
                let id = DocId::from_url(&url)?;
                let spans = repo.read_doc(id, |doc| shapes::spans_to_json(doc)).await?;
                Ok::<_, anyhow::Error>(serde_json::to_string(&spans)?)
            })
            .await??;
        Ok(json)
    }

    pub async fn note_spans_snapshot(&self, url: String) -> Result<NoteSpansSnapshot, CoreError> {
        let repo = self.repo.clone();
        let snapshot = self
            .run(async move {
                let id = DocId::from_url(&url)?;
                repo.read_doc(id, |doc| {
                    let spans = shapes::spans_to_json(doc)?;
                    Ok::<_, anyhow::Error>(NoteSpansSnapshot {
                        spans_json: serde_json::to_string(&spans)?,
                        heads: encode_heads(doc.get_heads()),
                    })
                })
                .await
            })
            .await??;
        Ok(snapshot)
    }

    pub fn update_note_spans(&self, url: String, spans_json: String) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let reindex_url = url.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                let spans: Vec<shapes::SpanJson> = serde_json::from_str(&spans_json)?;
                repo.change_doc(id, |doc| {
                    shapes::update_spans_from_json(doc, &spans)?;
                    Ok(())
                })
                .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            self.reindex_doc(DocId::from_url(&reindex_url)?);
            Ok(())
        })
    }

    pub fn splice_note_text(
        &self,
        url: String,
        index: u64,
        delete_count: i64,
        insert: String,
        title: String,
        heads: Vec<String>,
    ) -> Result<Vec<String>, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let heads = decode_heads(heads)?;
            let current_heads = self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                repo.change_doc_at_deferred_save(id, heads, |doc| {
                    shapes::splice_note_text(doc, index as usize, delete_count, &insert, &title)?;
                    Ok(())
                })
                .await?;
                repo.read_doc(id, |doc| Ok(encode_heads(doc.get_heads())))
                    .await
            })?;
            Ok(current_heads)
        })
    }

    pub fn apply_note_mark(
        &self,
        url: String,
        start: u64,
        end: u64,
        name: String,
        value_json: Option<String>,
        title: String,
        heads: Vec<String>,
    ) -> Result<Vec<String>, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let heads = decode_heads(heads)?;
            let current_heads = self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                let value = value_json
                    .map(|json| serde_json::from_str(&json))
                    .transpose()?;
                repo.change_doc_at_deferred_save(id, heads, |doc| {
                    shapes::apply_note_mark(
                        doc,
                        start as usize,
                        end as usize,
                        &name,
                        value,
                        &title,
                    )?;
                    Ok(())
                })
                .await?;
                repo.read_doc(id, |doc| Ok(encode_heads(doc.get_heads())))
                    .await
            })?;
            Ok(current_heads)
        })
    }

    /// Like `update_note_spans`, but the commit is stamped with the given
    /// unix-seconds timestamp — used by importers to preserve edit dates.
    pub fn update_note_spans_at(
        &self,
        url: String,
        spans_json: String,
        timestamp: i64,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let reindex_url = url.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                let spans: Vec<shapes::SpanJson> = serde_json::from_str(&spans_json)?;
                repo.change_doc(id, |doc| {
                    shapes::update_spans_from_json_at(doc, &spans, timestamp)?;
                    Ok(())
                })
                .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            self.reindex_doc(DocId::from_url(&reindex_url)?);
            Ok(())
        })
    }

    pub fn create_script_in(&self, folder_url: String, name: String) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let script = repo
                .create_doc(|doc| shapes::init_script(doc, &name))
                .await?;
            let folder = DocId::from_url(&folder_url)?;
            repo.change_doc(folder, |doc| {
                shapes::add_folder_entry(
                    doc,
                    &shapes::DocLink {
                        name: name.clone(),
                        kind: "file".into(),
                        url: script.to_url(),
                        lush: Some("script".into()),
                    },
                )
            })
            .await?;
            Ok::<_, anyhow::Error>(script.to_url())
        })?;
        Ok(url)
    }

    /// Store a note's embedded passages, replacing any it already had.
    pub fn set_note_embeddings(
        &self,
        url: String,
        name: String,
        digest: String,
        chunks: Vec<EmbeddingChunk>,
    ) -> Result<(), CoreError> {
        self.index
            .set_embeddings(&url, &name, &digest, &chunks)
            .map_err(|e| CoreError::General { msg: e.to_string() })
    }

    pub fn remove_note_embeddings(&self, url: String) {
        if let Err(e) = self.index.remove_embeddings(&url) {
            tracing::warn!(error = %e, "embedding remove failed");
        }
    }

    /// Indexed file docs with no `@computervision` metadata yet, for the
    /// analyzer to backfill. Only images will actually yield anything.
    pub fn assets_without_vision(&self, limit: u32) -> Vec<String> {
        self.index.assets_without_vision(limit).unwrap_or_default()
    }

    /// Record that the analyzer has looked at this asset, so a fruitless one
    /// (audio, a blank image) is not retried on every backfill.
    pub fn mark_vision_attempted(&self, url: String) {
        if let Err(e) = self.index.mark_vision_attempted(&url) {
            tracing::warn!(error = %e, "vision attempt mark failed");
        }
    }

    /// Digest of the text a note's stored embeddings were built from.
    pub fn note_embedding_digest(&self, url: String) -> Option<String> {
        self.index.embedding_digest(&url).unwrap_or_default()
    }

    /// url -> text digest for every embedded note. A backfill compares against
    /// this instead of re-embedding notes that have not changed.
    pub fn note_embedding_digests(&self) -> HashMap<String, String> {
        self.index.embedding_digests().unwrap_or_default()
    }

    /// Notes whose closest passage is nearest `vector`, best first.
    pub fn semantic_search(
        &self,
        vector: Vec<f32>,
        limit: u32,
        excluding: Vec<String>,
    ) -> Vec<SearchHit> {
        self.index
            .semantic_search(&vector, limit, &excluding)
            .unwrap_or_default()
    }

    /// Locally indexed notes, newest first. Served entirely from the search
    /// index, so it costs one SQL query rather than a read per note.
    pub fn recent_notes(&self, limit: u32) -> Vec<RecentNote> {
        self.index.recent_notes(limit).unwrap_or_default()
    }

    /// Unix seconds of the newest change in the doc (0 when unknown).
    pub fn note_modified(&self, url: String) -> i64 {
        let Ok(id) = DocId::from_url(&url) else {
            return 0;
        };
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| Ok(shapes::doc_modified(doc))))
            .unwrap_or(0)
    }

    /// Create a note inside a specific folder doc.
    pub fn create_note_in(&self, folder_url: String, title: String) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let url = self.runtime.block_on(async move {
                let folder = DocId::from_url(&folder_url)?;
                let note = repo
                    .create_doc(|doc| shapes::init_rich_note(doc, &title))
                    .await?;
                repo.change_doc(folder, |doc| {
                    shapes::add_folder_entry(
                        doc,
                        &shapes::DocLink {
                            name: title.clone(),
                            kind: "rich".into(),
                            url: note.to_url(),
                            lush: None,
                        },
                    )
                })
                .await?;
                Ok::<_, anyhow::Error>(note.to_url())
            })?;
            self.reindex_doc(DocId::from_url(&url)?);
            Ok(url)
        })
    }

    /// Flush all pending saves and do a best-effort final sync before the app
    /// exits. Should be called from applicationWillTerminate / sceneDidDisconnect.
    pub fn shutdown(&self) {
        let repo = self.repo.clone();
        self.runtime.block_on(async move { repo.shutdown().await });
    }

    /// Create a folder doc inside a specific folder doc.
    pub fn create_subfolder_in(
        &self,
        folder_url: String,
        title: String,
    ) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let url = self.runtime.block_on(async move {
                let folder = DocId::from_url(&folder_url)?;
                let sub = repo
                    .create_doc(|doc| shapes::init_folder(doc, &title))
                    .await?;
                repo.change_doc(folder, |doc| {
                    shapes::add_folder_entry(
                        doc,
                        &shapes::DocLink {
                            name: title.clone(),
                            kind: "folder".into(),
                            url: sub.to_url(),
                            lush: None,
                        },
                    )
                })
                .await?;
                Ok::<_, anyhow::Error>(sub.to_url())
            })?;
            Ok(url)
        })
    }
}
