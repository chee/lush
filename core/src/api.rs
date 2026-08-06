use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    str::FromStr,
    sync::Arc,
    time::Duration,
};

use automerge::{ChangeHash, ChangeMetadata};
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

#[derive(Debug, Clone, uniffi::Record)]
pub struct DocHistoryEntry {
    pub hash: String,
    pub heads: Vec<String>,
    pub time: i64,
    pub actor: String,
    pub seq: u64,
    pub message: Option<String>,
    pub deps: Vec<String>,
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
pub struct StorageChunk {
    pub digest: String,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AccountState {
    pub account_url: String,
    pub contact_url: Option<String>,
    pub root_folder_url: Option<String>,
    pub config_url: Option<String>,
    pub folders: Vec<String>,
    pub inbox: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ContactInfo {
    pub name: String,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ConfigState {
    pub folders: Vec<String>,
    pub inbox: Option<String>,
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

#[derive(Debug, Clone, uniffi::Record)]
pub struct AssetML {
    pub summary: String,
    pub caption: String,
    pub keywords: String,
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
    history_cache: std::sync::Mutex<HashMap<DocId, CachedDocHistory>>,
}

#[derive(Clone)]
struct CachedDocHistory {
    heads: Vec<ChangeHash>,
    frontier: HashSet<ChangeHash>,
    known_hashes: HashSet<ChangeHash>,
    entries: Vec<DocHistoryEntry>,
}

fn normalized_heads(mut heads: Vec<ChangeHash>) -> Vec<ChangeHash> {
    heads.sort_by(|a, b| a.to_string().cmp(&b.to_string()));
    heads
}

fn append_history_entries(history: &mut CachedDocHistory, changes: Vec<ChangeMetadata<'_>>) {
    for change in changes {
        if !history.known_hashes.insert(change.hash) {
            continue;
        }
        for dep in &change.deps {
            history.frontier.remove(dep);
        }
        history.frontier.insert(change.hash);
        let mut heads: Vec<String> = history.frontier.iter().map(ToString::to_string).collect();
        heads.sort();
        history.entries.push(DocHistoryEntry {
            hash: change.hash.to_string(),
            heads,
            time: change.timestamp,
            actor: change.actor.to_string(),
            seq: change.seq,
            message: change.message.map(|message| message.into_owned()),
            deps: change.deps.into_iter().map(|dep| dep.to_string()).collect(),
        });
    }
}

const OPEN_TIMEOUT: Duration = Duration::from_secs(60);
const LINK_TIMEOUT: Duration = Duration::from_secs(5);

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
        static TRACING: std::sync::Once = std::sync::Once::new();
        TRACING.call_once(|| {
            let _ = tracing_subscriber::fmt()
                .with_env_filter(
                    tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                        "lush_core=debug,subduction_websocket=warn,subduction_core=warn,warn".into()
                    }),
                )
                .try_init();
        });
        tracing::info!("lush-core built {}", env!("LUSH_BUILD_TS"));
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
            history_cache: std::sync::Mutex::new(HashMap::new()),
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
                        delegate.on_sync_event(format!(
                            "[warn] delegate missed {n} events — some updates may be delayed"
                        ));
                    }
                    Err(_) => break,
                }
            }
        });
    }

    pub fn resync_doc(&self, url: String) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        let id = DocId::from_url(&url)?;
        self.history_cache.lock().unwrap().remove(&id);
        self.runtime.block_on(async move {
            repo.drop_doc(id).await;
            repo.ensure_doc(id).await
        })?;
        Ok(())
    }

    pub fn doc_change_count(&self, url: String) -> u32 {
        let Ok(id) = DocId::from_url(&url) else {
            return 0;
        };
        self.runtime
            .block_on(
                self.repo
                    .read_doc(id, |doc| Ok(doc.get_changes(&[]).len() as u32)),
            )
            .unwrap_or(0)
    }

    pub fn doc_history(&self, url: String) -> Vec<DocHistoryEntry> {
        let Ok(id) = DocId::from_url(&url) else {
            return Vec::new();
        };
        let cached = self.history_cache.lock().unwrap().get(&id).cloned();
        let history = self
            .runtime
            .block_on(self.repo.read_doc(id, move |doc| {
                let current_heads = normalized_heads(doc.get_heads());
                if let Some(cached) = cached {
                    if cached.heads == current_heads {
                        return Ok(cached);
                    }

                    let changes = doc.get_changes_meta(&cached.heads);
                    if !cached.heads.is_empty() && !changes.is_empty() {
                        let mut next = cached;
                        next.heads = current_heads;
                        append_history_entries(&mut next, changes);
                        return Ok(next);
                    }
                }

                let mut next = CachedDocHistory {
                    heads: current_heads,
                    frontier: HashSet::new(),
                    known_hashes: HashSet::new(),
                    entries: Vec::new(),
                };
                append_history_entries(&mut next, doc.get_changes_meta(&[]));
                Ok(next)
            }))
            .ok();

        let Some(history) = history else {
            return Vec::new();
        };
        let entries = history.entries.clone();
        self.history_cache.lock().unwrap().insert(id, history);
        entries
    }

    pub fn is_connected(&self) -> bool {
        self.repo.is_connected()
    }

    /// Port of the loopback subduction listener the core hosts, if it bound.
    /// Webviews connect here to sync against the core's own storage.
    pub fn local_server_port(&self) -> Option<u16> {
        self.repo.local_server_port()
    }

    pub fn iroh_node_id(&self) -> Option<String> {
        self.repo.iroh_node_id()
    }

    pub fn local_http_url(&self) -> Option<String> {
        self.repo.local_http_url()
    }

    pub fn add_iroh_peer(&self, node_id: String) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        self.runtime
            .block_on(async move { repo.add_iroh_peer(node_id).await })?;
        Ok(())
    }

    pub fn doc_storage_chunks(&self, url: String) -> Vec<StorageChunk> {
        let Ok(id) = DocId::from_url(&url) else {
            return Vec::new();
        };
        self.runtime
            .block_on(self.repo.doc_chunks(id))
            .into_iter()
            .map(|(digest, bytes)| StorageChunk { digest, bytes })
            .collect()
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
    /// Log in with a patchwork account doc: syncs it, ensures the lush config
    /// doc exists at `.tools.lush`, and on first login creates the
    /// "🍡 Lush notes" folder inside the account's root folder, seeding
    /// `.folders` and `.inbox` with it.
    pub fn login_account(&self, account_url: String) -> Result<AccountState, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let state = self.runtime.block_on(async move {
                let account = DocId::from_url(&account_url)?;
                repo.ensure_doc(account).await?;
                if !repo.wait_for_doc(account, OPEN_TIMEOUT).await {
                    anyhow::bail!("account doc not found locally or on the server");
                }
                let (contact_url, root_folder_url, mut config_url) = repo
                    .read_doc(account, |doc| {
                        Ok((
                            shapes::account_field(doc, "contactUrl"),
                            shapes::account_field(doc, "rootFolderUrl"),
                            shapes::account_tools_lush(doc),
                        ))
                    })
                    .await?;
                if config_url.is_none() {
                    let created = repo.create_doc(shapes::init_lush_config).await?;
                    let url = created.to_url();
                    repo.change_doc(account, |doc| shapes::set_account_tools_lush(doc, &url))
                        .await?;
                    config_url = Some(url);
                }
                let config_url = config_url.expect("config url ensured above");
                let config = DocId::from_url(&config_url)?;
                repo.ensure_doc(config).await?;
                let _ = repo.wait_for_doc(config, LINK_TIMEOUT).await;
                let (mut folders, mut inbox) = repo
                    .read_doc(config, |doc| {
                        Ok((shapes::config_folders(doc), shapes::config_inbox(doc)))
                    })
                    .await?;
                if folders.is_empty() {
                    if let Some(root_url) = &root_folder_url {
                        let root = DocId::from_url(root_url)?;
                        repo.ensure_doc(root).await?;
                        if repo.wait_for_doc(root, OPEN_TIMEOUT).await {
                            let title = "🍡 Lush notes".to_string();
                            let sub = repo
                                .create_doc(|doc| shapes::init_folder(doc, &title))
                                .await?;
                            repo.change_doc(root, |doc| {
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
                            folders = vec![sub.to_url()];
                            inbox = Some(sub.to_url());
                            let urls = folders.clone();
                            let inbox_url = sub.to_url();
                            repo.change_doc(config, move |doc| {
                                shapes::config_set_folders(doc, &urls)?;
                                shapes::config_set_inbox(doc, &inbox_url)
                            })
                            .await?;
                        }
                    }
                } else if inbox.is_none() {
                    inbox = folders.first().cloned();
                    if let Some(inbox_url) = inbox.clone() {
                        repo.change_doc(config, move |doc| {
                            shapes::config_set_inbox(doc, &inbox_url)
                        })
                        .await?;
                    }
                }
                Ok::<_, anyhow::Error>(AccountState {
                    account_url: account_url.clone(),
                    contact_url,
                    root_folder_url,
                    config_url: Some(config_url),
                    folders,
                    inbox,
                })
            })?;
            Ok(state)
        })
    }

    pub fn contact_info(&self, url: String) -> Option<ContactInfo> {
        let id = DocId::from_url(&url).ok()?;
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let _ = repo.ensure_doc(id).await;
            if !repo.wait_for_doc(id, LINK_TIMEOUT).await {
                return None;
            }
            repo.read_doc(id, |doc| {
                Ok(ContactInfo {
                    name: shapes::doc_field(doc, "name"),
                    avatar_url: shapes::account_field(doc, "avatarUrl"),
                })
            })
            .await
            .ok()
        })
    }

    pub fn config_state(&self, config_url: String) -> Option<ConfigState> {
        let id = DocId::from_url(&config_url).ok()?;
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            repo.read_doc(id, |doc| {
                Ok(ConfigState {
                    folders: shapes::config_folders(doc),
                    inbox: shapes::config_inbox(doc),
                })
            })
            .await
            .ok()
        })
    }

    pub fn set_config_folders(
        &self,
        config_url: String,
        urls: Vec<String>,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&config_url)?;
                repo.change_doc(id, move |doc| shapes::config_set_folders(doc, &urls))
                    .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn set_config_inbox(&self, config_url: String, url: String) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&config_url)?;
                repo.change_doc(id, move |doc| shapes::config_set_inbox(doc, &url))
                    .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    /// Fix a folder entry whose name or type drifted from the doc it points
    /// at — runs when the doc is opened, so stale entries heal over time.
    pub fn refresh_folder_entry(&self, folder_url: String, url: String) {
        let repo = self.repo.clone();
        self.runtime.spawn(async move {
            let (Ok(folder), Ok(id)) = (DocId::from_url(&folder_url), DocId::from_url(&url)) else {
                return;
            };
            if !repo.wait_for_doc(id, LINK_TIMEOUT).await {
                return;
            }
            let Ok((name, kind)) = repo
                .read_doc(id, |doc| {
                    Ok((
                        shapes::doc_title(doc),
                        shapes::doc_patchwork_type(doc).unwrap_or_default(),
                    ))
                })
                .await
            else {
                return;
            };
            let _ = repo
                .change_doc(folder, |doc| {
                    shapes::refresh_folder_entry(doc, &url, &name, &kind)
                })
                .await;
        });
    }

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
    /// The folder entry's name and type come from the doc itself when the
    /// caller has none — picker-created patchwork docs arrive here with no
    /// title, and their type is whatever their datatype says, not "rich".
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
            let mut name = title;
            let mut kind = "rich".to_string();
            if let Ok(id) = DocId::from_url(&note_url) {
                let _ = repo.ensure_doc(id).await;
                if repo.wait_for_doc(id, LINK_TIMEOUT).await {
                    if let Ok((doc_name, doc_kind)) = repo
                        .read_doc(id, |doc| {
                            Ok((shapes::doc_title(doc), shapes::doc_patchwork_type(doc)))
                        })
                        .await
                    {
                        if name.is_empty() {
                            name = doc_name;
                        }
                        if let Some(doc_kind) = doc_kind {
                            kind = doc_kind;
                        }
                    }
                }
            }
            repo.change_doc(folder, |doc| {
                shapes::add_folder_entry(
                    doc,
                    &shapes::DocLink {
                        name,
                        kind,
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

    /// Write generated ML metadata onto a UnixFileEntry doc.
    pub fn update_asset_ml(
        &self,
        url: String,
        summary: String,
        caption: String,
        keywords: String,
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
                shapes::set_ml_metadata(doc, &summary, &caption, &keywords)
            })
            .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        self.reindex_doc(DocId::from_url(&reindex_url)?);
        Ok(())
    }

    pub fn asset_ml(&self, url: String) -> Option<AssetML> {
        let id = DocId::from_url(&url).ok()?;
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| Ok(shapes::asset_ml(doc))))
            .ok()
            .flatten()
            .map(|(summary, caption, keywords)| AssetML {
                summary,
                caption,
                keywords,
            })
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

    pub async fn note_spans_snapshot_at(
        &self,
        url: String,
        heads: Vec<String>,
    ) -> Result<NoteSpansSnapshot, CoreError> {
        let repo = self.repo.clone();
        let heads = decode_heads(heads)?;
        let snapshot = self
            .run(async move {
                let id = DocId::from_url(&url)?;
                repo.read_doc(id, |doc| {
                    let current_heads = doc.get_heads();
                    let view;
                    let doc = if heads.is_empty() || current_heads == heads {
                        doc
                    } else {
                        view = doc.fork_at(&heads)?;
                        &view
                    };
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
