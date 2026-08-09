use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    str::FromStr,
    sync::Arc,
    time::Duration,
};

use automerge::{Change, ChangeHash};
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
    pub additions: u64,
    pub deletions: u64,
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
pub struct CloneResult {
    pub clone_url: String,
    pub cloned_at: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CheckpointPin {
    pub original_url: String,
    pub heads: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CloneEntryFfi {
    pub original_url: String,
    pub clone_url: String,
    pub cloned_at: Vec<String>,
    pub merged_at: Option<Vec<String>>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DraftState {
    pub is_main: bool,
    pub name: Option<String>,
    pub parent: String,
    pub drafts: Vec<String>,
    pub clones: Vec<CloneEntryFfi>,
    pub merged_at: Option<i64>,
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

/// An iroh peer. `added` peers are dialed on launch; the rest dialed us and
/// are offered as suggestions.
#[derive(Debug, Clone, uniffi::Record)]
pub struct IrohPeer {
    pub node_id: String,
    /// Their friend code, if their subduction peer id is known — otherwise
    /// just the node id.
    pub code: String,
    pub added: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AccountState {
    pub account_url: String,
    pub contact_url: Option<String>,
    pub root_folder_url: Option<String>,
    pub module_settings_url: Option<String>,
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
    pub smart: Vec<shapes::SmartNotebook>,
    pub packages: Vec<String>,
    pub pad: Option<String>,
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
    fn on_ephemeral_message(&self, url: String, payload: Vec<u8>);
    fn on_peers_changed(&self);
}

#[derive(uniffi::Object)]
pub struct Core {
    runtime: Runtime,
    repo: Arc<Repo>,
    index: Arc<SearchIndex>,
    folder: std::sync::Mutex<Option<DocId>>,
    history_cache: std::sync::Mutex<HashMap<DocId, Arc<CachedDocHistory>>>,
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

fn append_history_entries(history: &mut CachedDocHistory, changes: Vec<Change>) {
    for change in changes {
        let hash = change.hash();
        if !history.known_hashes.insert(hash) {
            continue;
        }
        for dep in change.deps() {
            history.frontier.remove(dep);
        }
        history.frontier.insert(hash);
        let mut heads: Vec<String> = history.frontier.iter().map(ToString::to_string).collect();
        heads.sort();
        let (additions, deletions) = edit_counts(&change);
        history.entries.push(DocHistoryEntry {
            hash: hash.to_string(),
            heads,
            time: change.timestamp(),
            actor: change.actor_id().to_string(),
            seq: change.seq(),
            message: change.message().map(ToOwned::to_owned),
            deps: change.deps().iter().map(ToString::to_string).collect(),
            additions,
            deletions,
        });
    }
}

/// +/- counts for one change, read straight off its ops: inserted elements
/// against deleted ones. Non-insert puts (titles, `@patchwork` metadata)
/// count as neither, so a metadata-only change reads 0/0 and the timeline
/// drops it — same intent as patchwork's diff-based computeEditCounts, but
/// without a diff per change (~150× faster over a long history).
fn edit_counts(change: &Change) -> (u64, u64) {
    let mut additions = 0u64;
    let mut deletions = 0u64;
    for op in change.decode().operations {
        if matches!(op.action, automerge::legacy::OpType::Delete) {
            deletions += 1;
        } else if op.insert {
            additions += 1;
        }
    }
    (additions, deletions)
}

const OPEN_TIMEOUT: Duration = Duration::from_secs(60);
const LINK_TIMEOUT: Duration = Duration::from_secs(5);
const HISTORY_CACHE_DOCS: usize = 8;
const ADOPTED_FOLDER_TITLE: &str = "📦 Lush items from before you logged in";

impl Core {
    fn start_index_updates(self: &Arc<Self>) {
        let mut events = self.repo.subscribe();
        let repo = self.repo.clone();
        let index = self.index.clone();
        let slots: Arc<IndexSlots> = Arc::new(std::sync::Mutex::new(HashMap::new()));
        self.runtime.spawn(async move {
            loop {
                match events.recv().await {
                    Ok(RepoEvent::DocChanged(id)) => {
                        schedule_index_doc(repo.clone(), index.clone(), slots.clone(), id);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!("index missed {n} events; reindexing tracked docs");
                        for id in repo.tracked_doc_ids().await {
                            schedule_index_doc(repo.clone(), index.clone(), slots.clone(), id);
                        }
                    }
                    Ok(_) => {}
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

#[derive(Default)]
struct IndexSlot {
    running: bool,
    again: bool,
}

type IndexSlots = std::sync::Mutex<HashMap<DocId, IndexSlot>>;

/// Serialize index updates per doc: while one runs, a new DocChanged sets
/// `again` instead of racing a second task. The rerun reads the doc's latest
/// state, so the newest write always lands last and the index can't go stale.
fn schedule_index_doc(
    repo: Arc<Repo>,
    index: Arc<SearchIndex>,
    slots: Arc<IndexSlots>,
    id: DocId,
) {
    {
        let mut map = slots.lock().unwrap();
        let slot = map.entry(id).or_default();
        if slot.running {
            slot.again = true;
            return;
        }
        slot.running = true;
    }
    tokio::spawn(async move {
        loop {
            index_doc(repo.clone(), index.clone(), id).await;
            let mut map = slots.lock().unwrap();
            match map.get_mut(&id) {
                Some(slot) if slot.again => slot.again = false,
                _ => {
                    map.remove(&id);
                    return;
                }
            }
        }
    });
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
        let boot = std::time::Instant::now();
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
        tracing::info!(
            elapsed_ms = boot.elapsed().as_millis(),
            "core runtime ready"
        );
        let server = server_url.unwrap_or_else(|| DEFAULT_SERVER.to_string());
        let data_dir = PathBuf::from(data_dir);
        let index = Arc::new(SearchIndex::open(&data_dir)?);
        tracing::info!(
            elapsed_ms = boot.elapsed().as_millis(),
            "search index opened"
        );
        let repo = runtime.block_on(Repo::start(data_dir, server))?;
        tracing::info!(elapsed_ms = boot.elapsed().as_millis(), "repo started");
        let core = Arc::new(Core {
            runtime,
            repo,
            index,
            folder: std::sync::Mutex::new(None),
            history_cache: std::sync::Mutex::new(HashMap::new()),
        });
        core.start_index_updates();
        tracing::info!(elapsed_ms = boot.elapsed().as_millis(), "core constructed");
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
                    Ok(RepoEvent::Ephemeral(id, payload)) => {
                        delegate.on_ephemeral_message(id.to_url(), payload)
                    }
                    Ok(RepoEvent::PeersChanged) => delegate.on_peers_changed(),
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

                    let changes = doc.get_changes(&cached.heads);
                    if !cached.heads.is_empty() && !changes.is_empty() {
                        let mut next = (*cached).clone();
                        next.heads = current_heads;
                        append_history_entries(&mut next, changes);
                        return Ok(Arc::new(next));
                    }
                }

                let mut next = CachedDocHistory {
                    heads: current_heads,
                    frontier: HashSet::new(),
                    known_hashes: HashSet::new(),
                    entries: Vec::new(),
                };
                append_history_entries(&mut next, doc.get_changes(&[]));
                Ok(Arc::new(next))
            }))
            .ok();

        let Some(history) = history else {
            return Vec::new();
        };
        let entries = history.entries.clone();
        {
            let mut cache = self.history_cache.lock().unwrap();
            if cache.len() >= HISTORY_CACHE_DOCS && !cache.contains_key(&id) {
                if let Some(evicted) = cache.keys().next().copied() {
                    cache.remove(&evicted);
                }
            }
            cache.insert(id, history);
        }
        entries
    }

    /// History restricted to changes not covered by `heads` — a draft
    /// clone's activity since its fork point. Per-entry heads start from the
    /// fork frontier so snapshots at any entry stay correct.
    pub fn doc_history_since(&self, url: String, heads: Vec<String>) -> Vec<DocHistoryEntry> {
        let Ok(id) = DocId::from_url(&url) else {
            return Vec::new();
        };
        let Ok(since) = decode_heads(heads) else {
            return Vec::new();
        };
        self.runtime
            .block_on(self.repo.read_doc(id, move |doc| {
                let mut history = CachedDocHistory {
                    heads: Vec::new(),
                    frontier: since.iter().copied().collect(),
                    known_hashes: HashSet::new(),
                    entries: Vec::new(),
                };
                append_history_entries(&mut history, doc.get_changes(&since));
                Ok(history.entries)
            }))
            .unwrap_or_default()
    }

    pub fn is_connected(&self) -> bool {
        self.repo.is_connected()
    }

    pub fn set_apply_incoming(&self, enabled: bool) {
        let repo = self.repo.clone();
        self.runtime
            .block_on(async move { repo.set_apply_incoming(enabled).await });
    }

    pub fn set_send_changes(&self, enabled: bool) {
        let repo = self.repo.clone();
        self.runtime
            .block_on(async move { repo.set_send_changes(enabled).await });
    }

    pub fn is_applying_incoming(&self) -> bool {
        self.repo.is_applying_incoming()
    }

    pub fn is_sending_changes(&self) -> bool {
        self.repo.is_sending_changes()
    }

    pub fn pending_change_count(&self, url: String) -> u32 {
        let Ok(id) = DocId::from_url(&url) else {
            return 0;
        };
        self.runtime.block_on(self.repo.pending_change_count(id))
    }

    pub fn pending_doc_history(&self, url: String) -> Vec<DocHistoryEntry> {
        let Ok(id) = DocId::from_url(&url) else {
            return Vec::new();
        };
        let repo = self.repo.clone();
        self.runtime
            .block_on(async move {
                let current: HashSet<ChangeHash> = repo
                    .read_doc(id, |doc| {
                        Ok(doc
                            .get_changes(&[])
                            .into_iter()
                            .map(|change| change.hash())
                            .collect())
                    })
                    .await?;
                let stored = repo.stored_doc(id).await?;
                let mut frontier = HashSet::new();
                let mut entries = Vec::new();
                for change in stored.get_changes(&[]) {
                    let hash = change.hash();
                    for dep in change.deps() {
                        frontier.remove(dep);
                    }
                    frontier.insert(hash);
                    if current.contains(&hash) {
                        continue;
                    }
                    let mut heads: Vec<String> = frontier.iter().map(ToString::to_string).collect();
                    heads.sort();
                    let (additions, deletions) = edit_counts(&change);
                    entries.push(DocHistoryEntry {
                        hash: hash.to_string(),
                        heads,
                        time: change.timestamp(),
                        actor: change.actor_id().to_string(),
                        seq: change.seq(),
                        message: change.message().map(ToOwned::to_owned),
                        deps: change.deps().iter().map(ToString::to_string).collect(),
                        additions,
                        deletions,
                    });
                }
                Ok::<_, anyhow::Error>(entries)
            })
            .unwrap_or_default()
    }

    /// Start the outbound sync-server connection loop. Idempotent — safe to
    /// call multiple times; only the first call takes effect.
    pub fn connect(self: &Arc<Self>) {
        let _guard = self.runtime.enter();
        self.repo.start_connect_loop_if_needed();
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

    pub fn add_iroh_peer(&self, code: String) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        self.runtime
            .block_on(async move { repo.add_iroh_peer(code).await })?;
        Ok(())
    }

    pub fn iroh_peers(&self) -> Vec<IrohPeer> {
        self.repo
            .iroh_peers()
            .into_iter()
            .map(|peer| IrohPeer {
                code: match &peer.peer_id {
                    Some(peer_id) => format!("{}:{peer_id}", peer.node_id),
                    None => peer.node_id.clone(),
                },
                node_id: peer.node_id,
                added: peer.added,
            })
            .collect()
    }

    /// This device's friend code: iroh node id and subduction peer id.
    pub fn iroh_friend_code(&self) -> Option<String> {
        self.repo.iroh_friend_code()
    }

    pub fn forget_iroh_peer(&self, node_id: String) {
        self.repo.forget_iroh_peer(&node_id);
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
                let (contact_url, root_folder_url, module_settings_url, mut config_url) = repo
                    .read_doc(account, |doc| {
                        Ok((
                            shapes::account_field(doc, "contactUrl"),
                            shapes::account_field(doc, "rootFolderUrl"),
                            shapes::account_field(doc, "moduleSettingsUrl"),
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
                    module_settings_url,
                    config_url: Some(config_url),
                    folders,
                    inbox,
                })
            })?;
            Ok(state)
        })
    }

    /// Fold pre-login local docs into the account just signed into: one folder
    /// holding every local root folder that has something in it, plus the
    /// pocket pad unless one of those folders already holds it. That folder
    /// goes to the top of the account's root folder and is appended to the
    /// lush config's `.folders`. Returns the merged folder list.
    pub fn adopt_local_docs(
        &self,
        account_url: String,
        folder_urls: Vec<String>,
        scratchpad_url: Option<String>,
    ) -> Result<Vec<String>, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let folders = self.runtime.block_on(async move {
                let account = DocId::from_url(&account_url)?;
                let (root_url, config_url) = repo
                    .read_doc(account, |doc| {
                        Ok((
                            shapes::account_field(doc, "rootFolderUrl"),
                            shapes::account_tools_lush(doc),
                        ))
                    })
                    .await?;
                let (Some(root_url), Some(config_url)) = (root_url, config_url) else {
                    anyhow::bail!("account has no root folder or lush config");
                };
                let root = DocId::from_url(&root_url)?;
                repo.ensure_doc(root).await?;
                if !repo.wait_for_doc(root, OPEN_TIMEOUT).await {
                    anyhow::bail!("account root folder not found locally or on the server");
                }
                let config = DocId::from_url(&config_url)?;
                let mut folders = repo
                    .read_doc(config, |doc| Ok(shapes::config_folders(doc)))
                    .await?;
                let mut linked: HashSet<String> = repo
                    .read_doc(root, |doc| shapes::folder_entries(doc))
                    .await?
                    .into_iter()
                    .map(|entry| entry.url)
                    .collect();
                linked.insert(root_url.clone());
                let mut adopted: Vec<shapes::DocLink> = Vec::new();
                let mut held: HashSet<String> = HashSet::new();
                for url in folder_urls {
                    if linked.contains(&url) || folders.contains(&url) {
                        continue;
                    }
                    let Ok(id) = DocId::from_url(&url) else { continue };
                    let Ok((title, entries)) = repo
                        .read_doc(id, |doc| Ok((shapes::doc_title(doc), shapes::folder_entries(doc)?)))
                        .await
                    else {
                        continue;
                    };
                    if entries.is_empty() {
                        continue;
                    }
                    held.extend(entries.into_iter().map(|entry| entry.url));
                    linked.insert(url.clone());
                    adopted.push(shapes::DocLink {
                        name: title,
                        kind: "folder".into(),
                        url,
                        lush: None,
                    });
                }
                if let Some(url) = scratchpad_url {
                    if !linked.contains(&url) && !held.contains(&url) {
                        if let Ok(id) = DocId::from_url(&url) {
                            if let Ok((name, kind)) = repo
                                .read_doc(id, |doc| {
                                    Ok((shapes::doc_title(doc), shapes::doc_patchwork_type(doc)))
                                })
                                .await
                            {
                                adopted.push(shapes::DocLink {
                                    name,
                                    kind: kind.unwrap_or_else(|| "rich".into()),
                                    url,
                                    lush: None,
                                });
                            }
                        }
                    }
                }
                if adopted.is_empty() {
                    return Ok(folders);
                }
                let title = ADOPTED_FOLDER_TITLE.to_string();
                let adopted_folder = repo
                    .create_doc(|doc| shapes::init_folder(doc, ADOPTED_FOLDER_TITLE))
                    .await?;
                for link in adopted.into_iter().rev() {
                    repo.change_doc(adopted_folder, move |doc| {
                        shapes::add_folder_entry(doc, &link)
                    })
                    .await?;
                }
                let link = shapes::DocLink {
                    name: title,
                    kind: "folder".into(),
                    url: adopted_folder.to_url(),
                    lush: None,
                };
                repo.change_doc(root, move |doc| shapes::add_folder_entry(doc, &link))
                    .await?;
                folders.push(adopted_folder.to_url());
                let urls = folders.clone();
                repo.change_doc(config, move |doc| shapes::config_set_folders(doc, &urls))
                    .await?;
                Ok::<_, anyhow::Error>(folders)
            })?;
            Ok(folders)
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
                    smart: shapes::config_smart_notebooks(doc),
                    packages: shapes::config_packages(doc),
                    pad: shapes::config_pad(doc),
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

    pub fn set_config_packages(
        &self,
        config_url: String,
        urls: Vec<String>,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&config_url)?;
                repo.change_doc(id, move |doc| shapes::config_set_packages(doc, &urls))
                    .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn set_config_smart_notebooks(
        &self,
        config_url: String,
        folders: Vec<shapes::SmartNotebook>,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&config_url)?;
                repo.change_doc(id, move |doc| {
                    shapes::config_set_smart_notebooks(doc, &folders)
                })
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

    // ---- scratchpads ----

    /// The note's own scratchpad, if it has one yet.
    pub fn note_pad(&self, url: String) -> Option<String> {
        let id = DocId::from_url(&url).ok()?;
        let repo = self.repo.clone();
        self.runtime
            .block_on(async move { repo.read_doc(id, |doc| Ok(shapes::note_pad(doc))).await.ok() })
            .flatten()
    }

    /// The note's scratchpad, made on first use and linked at `@lush.pad`.
    pub fn ensure_note_pad(&self, url: String) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let pad = self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                let (existing, title) = repo
                    .read_doc(id, |doc| Ok((shapes::note_pad(doc), shapes::doc_title(doc))))
                    .await?;
                if let Some(existing) = existing {
                    return Ok::<_, anyhow::Error>(existing);
                }
                let pad = repo
                    .create_doc(|doc| shapes::init_pad(doc, &format!("{title} scratchpad")))
                    .await?;
                let pad_url = pad.to_url();
                let linked = pad_url.clone();
                repo.change_doc(id, move |doc| shapes::set_note_pad(doc, &linked))
                    .await?;
                Ok(pad_url)
            })?;
            Ok(pad)
        })
    }

    /// The app-wide pocket pad, made on first use and recorded in the config.
    pub fn ensure_pocket_pad(&self, config_url: String) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let pad = self.runtime.block_on(async move {
                let id = DocId::from_url(&config_url)?;
                if let Some(existing) = repo.read_doc(id, |doc| Ok(shapes::config_pad(doc))).await? {
                    return Ok::<_, anyhow::Error>(existing);
                }
                let pad = repo
                    .create_doc(|doc| shapes::init_pad(doc, "Pocket Pad"))
                    .await?;
                let pad_url = pad.to_url();
                let linked = pad_url.clone();
                repo.change_doc(id, move |doc| shapes::config_set_pad(doc, &linked))
                    .await?;
                Ok(pad_url)
            })?;
            Ok(pad)
        })
    }

    /// A pad with nothing pointing at it yet — for a device with no account,
    /// where the caller remembers the url itself.
    pub fn create_pad(&self, title: String) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let url = self.runtime.block_on(async move {
                let pad = repo.create_doc(|doc| shapes::init_pad(doc, &title)).await?;
                Ok::<_, anyhow::Error>(pad.to_url())
            })?;
            Ok(url)
        })
    }

    pub fn pad_items(&self, url: String) -> Vec<shapes::PadItem> {
        let Ok(id) = DocId::from_url(&url) else {
            return Vec::new();
        };
        let repo = self.repo.clone();
        self.runtime
            .block_on(async move { repo.read_doc(id, |doc| Ok(shapes::pad_items(doc))).await })
            .unwrap_or_default()
    }

    pub fn pad_put_item(&self, url: String, item: shapes::PadItem) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                repo.change_doc(id, move |doc| shapes::pad_put_item(doc, &item))
                    .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn pad_move_item(
        &self,
        url: String,
        item_id: String,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                repo.change_doc(id, move |doc| {
                    shapes::pad_move_item(doc, &item_id, x, y, w, h)?;
                    Ok(())
                })
                .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn pad_set_data(
        &self,
        url: String,
        item_id: String,
        data: String,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                repo.change_doc(id, move |doc| {
                    shapes::pad_set_data(doc, &item_id, &data)?;
                    Ok(())
                })
                .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn pad_remove_item(&self, url: String, item_id: String) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                repo.change_doc(id, move |doc| {
                    shapes::pad_remove_item(doc, &item_id)?;
                    Ok(())
                })
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
                let current = repo
                    .read_doc(id, |doc| {
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
                    .await;
                let result: anyhow::Result<NoteSpansSnapshot> = match current {
                    Ok(snapshot) => Ok(snapshot),
                    Err(_) => {
                        let stored = repo.stored_doc(id).await?;
                        let view;
                        let doc = if heads.is_empty() || stored.get_heads() == heads {
                            &stored
                        } else {
                            view = stored.fork_at(&heads)?;
                            &view
                        };
                        let spans = shapes::spans_to_json(doc)?;
                        Ok(NoteSpansSnapshot {
                            spans_json: serde_json::to_string(&spans)?,
                            heads: encode_heads(doc.get_heads()),
                        })
                    }
                };
                result
            })
            .await??;
        Ok(snapshot)
    }

    /// Replace the note's content with the given spans. When `heads` is
    /// provided and the doc has advanced past them, the update is applied on a
    /// fork at those heads and merged back (the `changeAt` pattern the splice
    /// path uses), so concurrent remote edits survive a stale full-document
    /// save. Returns the doc's heads after the change.
    pub fn update_note_spans(
        &self,
        url: String,
        spans_json: String,
        heads: Option<Vec<String>>,
    ) -> Result<Vec<String>, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let reindex_url = url.clone();
            let heads = decode_heads(heads.unwrap_or_default())?;
            let new_heads = self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                let spans: Vec<shapes::SpanJson> = serde_json::from_str(&spans_json)?;
                if heads.is_empty() {
                    repo.change_doc(id, |doc| {
                        shapes::update_spans_from_json(doc, &spans)?;
                        Ok(())
                    })
                    .await?;
                } else {
                    repo.change_doc_at(id, heads, |doc| {
                        shapes::update_spans_from_json(doc, &spans)?;
                        Ok(())
                    })
                    .await?;
                }
                repo.read_doc(id, |doc| Ok(encode_heads(doc.get_heads())))
                    .await
            })?;
            self.reindex_doc(DocId::from_url(&reindex_url)?);
            Ok(new_heads)
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

    /// Sign and broadcast opaque ephemeral bytes on the doc's topic.
    /// Fire-and-forget: returns once the send is queued, not delivered.
    pub fn publish_ephemeral(&self, url: String, payload: Vec<u8>) -> Result<(), CoreError> {
        let id = DocId::from_url(&url)?;
        let repo = self.repo.clone();
        self.runtime
            .spawn(async move { repo.publish_ephemeral(id, payload).await });
        Ok(())
    }

    /// A stable automerge cursor string for an index into the note text
    /// (the same text field the splice/spans APIs target).
    /// Called synchronously from the UI thread, so it never waits on the doc
    /// lock: a busy doc is an error the caller retries on its next tick.
    pub fn text_cursor(&self, url: String, index: u64) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let cursor = self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.try_read_doc(id, |doc| shapes::text_cursor(doc, index as usize))
                .await
        })?;
        Ok(cursor)
    }

    /// The current index of an automerge cursor into the note text.
    /// Non-blocking like `text_cursor`.
    pub fn cursor_index(&self, url: String, cursor: String) -> Result<u64, CoreError> {
        let repo = self.repo.clone();
        let index = self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.try_read_doc(id, |doc| shapes::cursor_index(doc, &cursor))
                .await
        })?;
        Ok(index as u64)
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

    /// Store binary data as a patchwork UnixFileEntry doc linked into a
    /// specific folder doc; returns the file doc's URL.
    pub fn create_asset_in(
        &self,
        folder_url: String,
        name: String,
        extension: String,
        mime_type: String,
        data: Vec<u8>,
    ) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let url = self.runtime.block_on(async move {
                let folder = DocId::from_url(&folder_url)?;
                let file = repo
                    .create_doc(|doc| {
                        shapes::init_file_doc(doc, &name, &extension, &mime_type, data)
                    })
                    .await?;
                repo.change_doc(folder, |doc| {
                    shapes::add_folder_entry(
                        doc,
                        &shapes::DocLink {
                            name: name.clone(),
                            kind: "file".into(),
                            url: file.to_url(),
                            lush: None,
                        },
                    )
                })
                .await?;
                Ok::<_, anyhow::Error>(file.to_url())
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

    /// Full-history fork of a doc installed as a new repo doc. `cloned_at`
    /// is the source's heads at fork time.
    pub fn clone_doc(&self, url: String) -> Result<CloneResult, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let result = self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                repo.ensure_doc(id).await?;
                if !repo.wait_for_doc(id, OPEN_TIMEOUT).await {
                    anyhow::bail!("doc not found locally or on the server");
                }
                let (fork, cloned_at) = repo
                    .read_doc(id, |doc| Ok((doc.fork(), encode_heads(doc.get_heads()))))
                    .await?;
                let clone = repo
                    .create_doc(move |doc| {
                        *doc = fork;
                        Ok(())
                    })
                    .await?;
                Ok::<_, anyhow::Error>(CloneResult {
                    clone_url: clone.to_url(),
                    cloned_at,
                })
            })?;
            Ok(result)
        })
    }

    /// Plain automerge merge of `from` into `into`; returns the target's
    /// heads after the merge.
    pub fn merge_doc(&self, into_url: String, from_url: String) -> Result<Vec<String>, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let reindex_url = into_url.clone();
            let heads = self.runtime.block_on(async move {
                let into = DocId::from_url(&into_url)?;
                let from = DocId::from_url(&from_url)?;
                repo.ensure_doc(from).await?;
                if !repo.wait_for_doc(from, OPEN_TIMEOUT).await {
                    anyhow::bail!("source doc not found locally or on the server");
                }
                repo.ensure_doc(into).await?;
                if !repo.wait_for_doc(into, OPEN_TIMEOUT).await {
                    anyhow::bail!("target doc not found locally or on the server");
                }
                let mut source = repo.read_doc(from, |doc| Ok(doc.fork())).await?;
                repo.change_doc(into, move |doc| {
                    doc.merge(&mut source)?;
                    Ok(())
                })
                .await?;
                repo.read_doc(into, |doc| Ok(encode_heads(doc.get_heads())))
                    .await
            })?;
            self.reindex_doc(DocId::from_url(&reindex_url)?);
            Ok(heads)
        })
    }

    pub fn create_draft_doc(&self, parent_url: String, is_main: bool) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let url = self.runtime.block_on(async move {
                let draft = repo
                    .create_doc(|doc| shapes::init_draft(doc, &parent_url, is_main))
                    .await?;
                Ok::<_, anyhow::Error>(draft.to_url())
            })?;
            Ok(url)
        })
    }

    pub fn create_checkout_doc(&self) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let url = self.runtime.block_on(async move {
                let doc = repo.create_doc(shapes::init_checkout).await?;
                Ok::<_, anyhow::Error>(doc.to_url())
            })?;
            Ok(url)
        })
    }

    pub fn set_checkout_state(
        &self,
        url: String,
        checked_out: Option<String>,
        pins: Option<Vec<CheckpointPin>>,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                let pins = pins.map(|pins| {
                    pins.into_iter()
                        .map(|pin| (pin.original_url, pin.heads))
                        .collect::<Vec<_>>()
                });
                repo.change_doc(id, move |doc| {
                    shapes::set_checkout_state(doc, checked_out.as_deref(), pins.as_deref())
                })
                .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn draft_add_child(&self, draft_url: String, child_url: String) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&draft_url)?;
                repo.change_doc(id, move |doc| shapes::draft_add_child(doc, &child_url))
                    .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    /// A heads-pinned automerge url (`automerge:<id>#<head>|<head>`,
    /// bs58check heads, sorted) — automerge-repo's read-only view format.
    pub fn pinned_doc_url(&self, url: String, heads: Vec<String>) -> Result<String, CoreError> {
        let id = DocId::from_url(&url)?;
        let mut wire: Vec<String> = heads.iter().map(|h| shapes::head_to_wire(h)).collect();
        wire.sort();
        Ok(format!("{}#{}", id.to_url(), wire.join("|")))
    }

    pub fn draft_set_name(&self, draft_url: String, name: Option<String>) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&draft_url)?;
                repo.change_doc(id, move |doc| shapes::draft_set_name(doc, name.as_deref()))
                    .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn draft_record_clone(
        &self,
        draft_url: String,
        original_url: String,
        clone_url: String,
        cloned_at: Vec<String>,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&draft_url)?;
                repo.change_doc(id, move |doc| {
                    shapes::draft_record_clone(doc, &original_url, &clone_url, &cloned_at)
                })
                .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn draft_record_merge(
        &self,
        draft_url: String,
        original_url: String,
        merged_at: Vec<String>,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&draft_url)?;
                repo.change_doc(id, move |doc| {
                    shapes::draft_record_merge(doc, &original_url, &merged_at)
                })
                .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn draft_mark_merged(&self, draft_url: String, timestamp_ms: i64) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&draft_url)?;
                repo.change_doc(id, move |doc| shapes::draft_mark_merged(doc, timestamp_ms))
                    .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    /// None when the doc is not a draft (`@patchwork.type != "draft"`).
    pub fn draft_state(&self, url: String) -> Result<Option<DraftState>, CoreError> {
        let repo = self.repo.clone();
        let shape = self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.read_doc(id, |doc| Ok(shapes::draft_shape(doc))).await
        })?;
        Ok(shape.map(|shape| DraftState {
            is_main: shape.is_main,
            name: shape.name,
            parent: shape.parent,
            drafts: shape.drafts,
            clones: shape
                .clones
                .into_iter()
                .map(|entry| CloneEntryFfi {
                    original_url: entry.original_url,
                    clone_url: entry.clone_url,
                    cloned_at: entry.cloned_at,
                    merged_at: entry.merged_at,
                })
                .collect(),
            merged_at: shape.merged_at,
        }))
    }

    pub fn main_draft_url(&self, doc_url: String) -> Result<Option<String>, CoreError> {
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let id = DocId::from_url(&doc_url)?;
            repo.read_doc(id, |doc| Ok(shapes::main_draft_url(doc)))
                .await
        })?;
        Ok(url)
    }

    pub fn set_main_draft_url(&self, doc_url: String, draft_url: String) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&doc_url)?;
                repo.change_doc(id, move |doc| shapes::set_main_draft_url(doc, &draft_url))
                    .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
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

#[cfg(test)]
mod tests {
    use super::*;

    fn test_core() -> (tempfile::TempDir, Arc<Core>) {
        let dir = tempfile::tempdir().unwrap();
        let core = Core::new(
            dir.path().to_string_lossy().into_owned(),
            Some("http://[".into()),
        )
        .unwrap();
        (dir, core)
    }

    fn heads(core: &Core, url: &str) -> Vec<String> {
        core.runtime.block_on(core.doc_heads(url.to_string()))
    }

    fn full_text(core: &Core, url: &str) -> String {
        let id = DocId::from_url(url).unwrap();
        core.runtime
            .block_on(core.repo.read_doc(id, |doc| Ok(shapes::full_text(doc))))
            .unwrap()
    }

    #[test]
    fn create_draft_doc_round_trips_through_draft_state() {
        let (_dir, core) = test_core();
        let note = core.create_note_doc("host".into()).unwrap();
        let main = core.create_draft_doc(note.clone(), true).unwrap();
        let child = core.create_draft_doc(main.clone(), false).unwrap();
        core.draft_add_child(main.clone(), child.clone()).unwrap();
        core.draft_set_name(child.clone(), Some("my draft".into()))
            .unwrap();
        let note_heads = heads(&core, &note);
        assert!(!note_heads.is_empty());
        core.draft_record_clone(
            child.clone(),
            note.clone(),
            "automerge:clone".into(),
            note_heads.clone(),
        )
        .unwrap();
        core.draft_record_merge(child.clone(), note.clone(), note_heads.clone())
            .unwrap();
        core.draft_mark_merged(child.clone(), 1_720_000_000_123)
            .unwrap();

        let state = core.draft_state(child.clone()).unwrap().unwrap();
        assert!(!state.is_main);
        assert_eq!(state.name.as_deref(), Some("my draft"));
        assert_eq!(state.parent, main);
        assert!(state.drafts.is_empty());
        assert_eq!(state.merged_at, Some(1_720_000_000_123));
        assert_eq!(state.clones.len(), 1);
        assert_eq!(state.clones[0].original_url, note);
        assert_eq!(state.clones[0].clone_url, "automerge:clone");
        assert_eq!(state.clones[0].cloned_at, note_heads);
        assert_eq!(state.clones[0].merged_at, Some(note_heads));

        let main_state = core.draft_state(main.clone()).unwrap().unwrap();
        assert!(main_state.is_main);
        assert_eq!(main_state.name, None);
        assert_eq!(main_state.parent, note);
        assert_eq!(main_state.drafts, vec![child.clone()]);
        assert_eq!(main_state.merged_at, None);
        assert!(main_state.clones.is_empty());

        core.draft_set_name(child.clone(), None).unwrap();
        assert_eq!(core.draft_state(child).unwrap().unwrap().name, None);

        assert!(core.draft_state(note).unwrap().is_none());
    }

    #[test]
    fn clone_doc_copies_content_and_captures_fork_heads() {
        let (_dir, core) = test_core();
        let note = core.create_note_doc("original".into()).unwrap();
        core.splice_note_text(
            note.clone(),
            1,
            0,
            "hello drafts".into(),
            "hello drafts".into(),
            heads(&core, &note),
        )
        .unwrap();
        let source_heads = heads(&core, &note);
        let result = core.clone_doc(note.clone()).unwrap();
        assert_ne!(result.clone_url, note);
        assert_eq!(result.cloned_at, source_heads);
        assert_eq!(full_text(&core, &result.clone_url), full_text(&core, &note));
        assert!(full_text(&core, &result.clone_url).contains("hello drafts"));
    }

    #[test]
    fn merge_doc_carries_clone_edits_back_to_the_source() {
        let (_dir, core) = test_core();
        let note = core.create_note_doc("note".into()).unwrap();
        core.splice_note_text(
            note.clone(),
            1,
            0,
            "hello".into(),
            "hello".into(),
            heads(&core, &note),
        )
        .unwrap();
        let clone = core.clone_doc(note.clone()).unwrap().clone_url;
        core.splice_note_text(
            clone.clone(),
            6,
            0,
            " from the draft".into(),
            "hello from the draft".into(),
            heads(&core, &clone),
        )
        .unwrap();
        let merged_heads = core.merge_doc(note.clone(), clone).unwrap();
        assert_eq!(full_text(&core, &note), "hello from the draft");
        assert_eq!(merged_heads, heads(&core, &note));
    }

    #[test]
    fn main_draft_url_round_trips_without_disturbing_the_doc() {
        let (_dir, core) = test_core();
        let note = core.create_note_doc("host".into()).unwrap();
        assert_eq!(core.main_draft_url(note.clone()).unwrap(), None);
        let draft = core.create_draft_doc(note.clone(), true).unwrap();
        core.set_main_draft_url(note.clone(), draft.clone())
            .unwrap();
        assert_eq!(core.main_draft_url(note.clone()).unwrap(), Some(draft));
        let id = DocId::from_url(&note).unwrap();
        let (kind, title) = core
            .runtime
            .block_on(core.repo.read_doc(id, |doc| {
                Ok((shapes::doc_patchwork_type(doc), shapes::doc_title(doc)))
            }))
            .unwrap();
        assert_eq!(kind.as_deref(), Some("rich"));
        assert_eq!(title, "host");
    }
}


