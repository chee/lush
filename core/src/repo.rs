use std::{
    collections::{BTreeSet, HashMap, HashSet},
    future::IntoFuture,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use automerge::{Automerge, ChangeHash};
use future_form::Sendable;
use sedimentree_core::{
    blob::{Blob, BlobMeta},
    collections::Map,
    depth::CountLeadingZeroBytes,
    fragment::Fragment,
    id::SedimentreeId,
    loose_commit::{id::CommitId, LooseCommit},
};
use subduction_redb_storage::RedbStorage;
use subduction_core::{
    collections::bounded_sharded_map::BoundedShardedMap,
    handler::sync::SyncHandler,
    handshake::audience::Audience,
    nonce_cache::NonceCache,
    peer::id::PeerId,
    policy::open::OpenPolicy,
    remote_heads::{RemoteHeads, RemoteHeadsObserver},
    storage::powerbox::StoragePowerbox,
    subduction::Subduction,
    timeout::call::CallTimeout,
    transport::message::MessageTransport,
};
use subduction_crypto::signer::memory::MemorySigner;
use subduction_websocket::tokio::{client::TokioWebSocketClient, TimeoutTokio, TokioSpawn};
use tokio::{
    sync::{broadcast, mpsc, Mutex},
    task::JoinHandle,
};

pub const DEFAULT_SERVER: &str = "wss://subduction.sync.inkandswitch.com";

const SYNC_TIMEOUT: CallTimeout = CallTimeout::TimeoutMillis(30_000);
const HEAL_DELAY: Duration = Duration::from_secs(5);
const HEAL_MAX_ATTEMPTS: u32 = 12;

type Conn = MessageTransport<TokioWebSocketClient<MemorySigner>>;
type Handler = SyncHandler<
    Sendable,
    RedbStorage,
    Conn,
    OpenPolicy,
    CountLeadingZeroBytes,
    TokioSpawn,
    256,
    HeadsObserver,
>;
type Core = Subduction<
    'static,
    Sendable,
    RedbStorage,
    Conn,
    Handler,
    OpenPolicy,
    MemorySigner,
    TimeoutTokio,
    TokioSpawn,
    CountLeadingZeroBytes,
    256,
>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DocId(pub [u8; 16]);

impl DocId {
    pub fn random() -> Self {
        let mut bytes = [0u8; 16];
        rand::fill(&mut bytes);
        DocId(bytes)
    }

    pub fn from_url(url: &str) -> Result<Self> {
        let stripped = url.trim().strip_prefix("automerge:").unwrap_or(url.trim());
        let stripped = stripped.split('#').next().unwrap_or(stripped);
        let decoded = bs58::decode(stripped)
            .with_check(None)
            .into_vec()
            .with_context(|| format!("invalid automerge url: {url}"))?;
        let bytes: [u8; 16] = decoded
            .as_slice()
            .try_into()
            .map_err(|_| anyhow!("document id is {} bytes, expected 16", decoded.len()))?;
        Ok(DocId(bytes))
    }

    pub fn to_url(self) -> String {
        format!(
            "automerge:{}",
            bs58::encode(self.0).with_check().into_string()
        )
    }

    pub fn sedimentree_id(self) -> SedimentreeId {
        let mut padded = [0u8; 32];
        padded[..16].copy_from_slice(&self.0);
        SedimentreeId::new(padded)
    }

    pub fn from_sedimentree_id(sid: SedimentreeId) -> Self {
        let bytes = sid.as_bytes();
        let mut out = [0u8; 16];
        out.copy_from_slice(&bytes[..16]);
        DocId(out)
    }
}

#[derive(Debug, Clone)]
pub enum RepoEvent {
    DocChanged(DocId),
    Connected,
    Disconnected,
    SyncEvent(String),
}

#[derive(Clone)]
struct HeadsObserver {
    tx: mpsc::UnboundedSender<(SedimentreeId, Vec<CommitId>)>,
}

impl RemoteHeadsObserver for HeadsObserver {
    fn on_remote_heads(&self, id: SedimentreeId, _peer: PeerId, heads: RemoteHeads) {
        let _ = self.tx.send((id, heads.heads));
    }
}

struct DocState {
    doc: Automerge,
    known: HashSet<ChangeHash>,
    fragments_unavailable: bool,
}

pub struct Repo {
    core: Arc<Core>,
    signer: MemorySigner,
    server_url: String,
    docs: Mutex<HashMap<DocId, DocState>>,
    pending_saves: Mutex<HashMap<DocId, JoinHandle<()>>>,
    events: broadcast::Sender<RepoEvent>,
    connected: std::sync::atomic::AtomicBool,
}

fn load_or_create_signer(path: &Path) -> Result<MemorySigner> {
    if let Ok(contents) = std::fs::read(path) {
        if contents.len() == 32 {
            let mut seed = [0u8; 32];
            seed.copy_from_slice(&contents);
            return Ok(MemorySigner::from_bytes(&seed));
        }
    }
    let mut seed = [0u8; 32];
    rand::fill(&mut seed);
    std::fs::write(path, seed).context("writing identity key")?;
    Ok(MemorySigner::from_bytes(&seed))
}

/// `Automerge::fragments` can panic on some change graphs (an upstream bug
/// where a level-1 change escapes the cached fragment clock). Treat panics as
/// "fragments unavailable" and fall back to per-change commits.
fn safe_fragments<R>(doc: &Automerge, levels: R) -> Option<Vec<automerge::Fragment>>
where
    R: std::ops::RangeBounds<usize>,
{
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| doc.fragments(levels))).ok()
}

fn safe_bundles(doc: &Automerge, frags: &[automerge::Fragment]) -> Option<Vec<Vec<u8>>> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        doc.bundle_fragments(frags.iter().cloned())
    }))
    .ok()
}

fn known_hashes(doc: &Automerge, fragments_unavailable: bool) -> (HashSet<ChangeHash>, bool) {
    if fragments_unavailable {
        return (
            doc.get_changes(&[]).iter().map(|c| c.hash()).collect(),
            true,
        );
    }
    match safe_fragments(doc, 0..) {
        Some(frags) => (frags.into_iter().map(|f| f.head).collect(), false),
        None => (
            doc.get_changes(&[]).iter().map(|c| c.hash()).collect(),
            true,
        ),
    }
}

impl Repo {
    pub async fn start(data_dir: PathBuf, server_url: String) -> Result<Arc<Repo>> {
        std::fs::create_dir_all(&data_dir).context("creating data dir")?;
        let signer = load_or_create_signer(&data_dir.join("identity.seed"))?;
        let storage = RedbStorage::with_settings(
            data_dir.join("sedimentree"),
            subduction_redb_storage::DEFAULT_INLINE_THRESHOLD,
            64 * 1024 * 1024,
        )
        .context("opening sedimentree storage")?;

        let (heads_tx, mut heads_rx) = mpsc::unbounded_channel();

        let sedimentrees = Arc::new(BoundedShardedMap::new());
        let connections = Arc::new(async_lock::Mutex::new(Map::new()));
        let subscriptions = Arc::new(async_lock::Mutex::new(Map::new()));
        let powerbox = StoragePowerbox::new(storage, Arc::new(OpenPolicy));
        let handler = Arc::new(SyncHandler::with_remote_heads_observer(
            sedimentrees.clone(),
            connections.clone(),
            subscriptions.clone(),
            powerbox.clone(),
            CountLeadingZeroBytes,
            HeadsObserver { tx: heads_tx },
            TokioSpawn,
        ));
        let send_counter = handler.send_counter().clone();
        let (core, listener_fut, manager_fut) = Subduction::new(
            handler,
            None,
            signer.clone(),
            sedimentrees,
            connections,
            subscriptions,
            powerbox,
            send_counter,
            NonceCache::default(),
            TimeoutTokio,
            Duration::from_secs(30),
            CountLeadingZeroBytes,
            TokioSpawn,
        );

        tokio::spawn(async move {
            if let Err(e) = listener_fut.await {
                tracing::error!(error = %e, "subduction listener exited");
            }
        });
        tokio::spawn(async move {
            if let Err(e) = manager_fut.await {
                tracing::error!(error = %e, "subduction manager exited");
            }
        });

        let (events, _) = broadcast::channel(256);
        let repo = Arc::new(Repo {
            core,
            signer,
            server_url,
            docs: Mutex::new(HashMap::new()),
            pending_saves: Mutex::new(HashMap::new()),
            events,
            connected: std::sync::atomic::AtomicBool::new(false),
        });

        {
            let repo = repo.clone();
            tokio::spawn(async move {
                while let Some((sid, heads)) = heads_rx.recv().await {
                    repo.on_remote_heads(sid, heads).await;
                }
            });
        }
        {
            let repo = repo.clone();
            tokio::spawn(async move { repo.connect_loop().await });
        }

        Ok(repo)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<RepoEvent> {
        self.events.subscribe()
    }

    pub fn is_connected(&self) -> bool {
        self.connected.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub async fn wait_connected(&self, timeout: Duration) -> bool {
        let deadline = tokio::time::Instant::now() + timeout;
        while !self.is_connected() {
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        true
    }

    async fn connect_loop(self: Arc<Self>) {
        let uri: tungstenite::http::Uri = match self.server_url.parse() {
            Ok(u) => u,
            Err(e) => {
                tracing::error!(error = %e, url = %self.server_url, "invalid server url");
                return;
            }
        };
        let host = uri.host().unwrap_or("localhost").to_string();
        let mut backoff = Duration::from_millis(500);
        loop {
            let audience = Audience::discover(host.as_bytes());
            match TokioWebSocketClient::new(uri.clone(), self.signer.clone(), audience).await {
                Ok((authenticated, listener_task, sender_task, keepalive_task)) => {
                    tracing::info!(peer = %authenticated.peer_id(), "connected to sync server");
                    let listener = tokio::spawn(listener_task.into_future());
                    let sender = tokio::spawn(sender_task.into_future());
                    let keepalive = tokio::spawn(async move {
                        keepalive_task.await;
                    });
                    if let Err(e) = self
                        .core
                        .add_connection(authenticated.map(MessageTransport::new))
                        .await
                    {
                        tracing::error!(error = %e, "failed to register connection");
                    } else {
                        backoff = Duration::from_millis(500);
                        self.connected
                            .store(true, std::sync::atomic::Ordering::Relaxed);
                        let _ = self.events.send(RepoEvent::Connected);
                        let repo = self.clone();
                        tokio::spawn(async move { repo.resync_all().await });
                        let _ = listener.await;
                    }
                    sender.abort();
                    keepalive.abort();
                    self.connected
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    let _ = self.events.send(RepoEvent::Disconnected);
                    tracing::info!("disconnected from sync server");
                }
                Err(e) => {
                    tracing::warn!(error = %e, "connection failed");
                }
            }
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(Duration::from_secs(30));
        }
    }

    async fn resync_all(self: Arc<Self>) {
        let ids: Vec<DocId> = self.docs.lock().await.keys().copied().collect();
        for id in ids {
            if let Err(e) = self
                .core
                .sync_with_all_peers(id.sedimentree_id(), true, SYNC_TIMEOUT)
                .await
            {
                tracing::warn!(error = %e, "resync failed");
                let _ = self.events.send(RepoEvent::SyncEvent(format!(
                    "resync {}: sync_with_all_peers failed: {e}",
                    &id.to_url()[11..23]
                )));
                continue;
            }
            self.apply_from_storage(id).await;
        }
    }

    async fn on_remote_heads(&self, sid: SedimentreeId, heads: Vec<CommitId>) {
        let id = DocId::from_sedimentree_id(sid);
        let tracked = self.docs.lock().await.contains_key(&id);
        if !tracked {
            return;
        }
        let changed = self.apply_from_storage(id).await;
        if changed {
            return;
        }
        let missing = {
            let docs = self.docs.lock().await;
            let Some(state) = docs.get(&id) else { return };
            heads.iter().any(|h| {
                let hash = ChangeHash(*h.as_bytes());
                !state.known.contains(&hash)
            })
        };
        if missing {
            let short = &id.to_url()[11..23];
            let _ = self.events.send(RepoEvent::SyncEvent(format!(
                "{short}: server has heads we're missing — pulling"
            )));
            if let Err(e) = self
                .core
                .sync_with_all_peers(sid, true, SYNC_TIMEOUT)
                .await
            {
                tracing::warn!(error = %e, "sync after remote heads failed");
                let _ = self.events.send(RepoEvent::SyncEvent(format!(
                    "{short}: pull failed: {e}"
                )));
            }
            self.apply_from_storage(id).await;
        }
    }

    /// Load every locally stored blob for the doc into the in-memory automerge
    /// document. Returns true (and emits DocChanged) if the doc advanced.
    async fn apply_from_storage(&self, id: DocId) -> bool {
        let blobs = match self.core.get_blobs(id.sedimentree_id()).await {
            Ok(Some(blobs)) => blobs,
            Ok(None) => return false,
            Err(e) => {
                tracing::warn!(error = %e, "get_blobs failed");
                return false;
            }
        };
        let blob_count = blobs.len();
        let mut docs = self.docs.lock().await;
        let Some(state) = docs.get_mut(&id) else {
            return false;
        };
        let before = state.doc.get_heads();
        let mut load_errors = 0u32;
        for blob in blobs.iter() {
            if let Err(e) = state.doc.load_incremental(blob.as_slice()) {
                tracing::warn!(error = %e, "load_incremental failed");
                load_errors += 1;
            }
        }
        let short = &id.to_url()[11..23];
        if state.doc.get_heads() == before {
            return false;
        }
        let (known, fragments_unavailable) = known_hashes(&state.doc, state.fragments_unavailable);
        state.known.extend(known);
        state.fragments_unavailable = fragments_unavailable;
        let new_heads = state.doc.get_heads().len();
        drop(docs);
        let _ = self.events.send(RepoEvent::SyncEvent(format!(
            "{short}: doc advanced, {blob_count} blobs, {new_heads} heads (load_errors={load_errors})"
        )));
        let _ = self.events.send(RepoEvent::DocChanged(id));
        true
    }

    /// Push any automerge fragments not yet in the sedimentree.
    async fn save_doc(&self, id: DocId) -> Result<()> {
        if let Some(handle) = self.pending_saves.lock().await.remove(&id) {
            handle.abort();
        }
        self.save_doc_now(id).await
    }

    async fn save_doc_now(&self, id: DocId) -> Result<()> {
        let sid = id.sedimentree_id();
        let (new_commits, new_cached, accepted_hashes) = {
            let mut docs = self.docs.lock().await;
            let state = docs
                .get_mut(&id)
                .ok_or_else(|| anyhow!("unknown doc {}", id.to_url()))?;
            let fragment_path = if state.fragments_unavailable {
                None
            } else {
                safe_fragments(&state.doc, 0..).and_then(|fragments| {
                    let mut loose = Vec::new();
                    let mut cached = Vec::new();
                    for fragment in fragments {
                        if state.known.contains(&fragment.head) {
                            continue;
                        }
                        if fragment.level == 0 {
                            loose.push(fragment);
                        } else {
                            cached.push(fragment);
                        }
                    }
                    let loose_bytes = safe_bundles(&state.doc, &loose)?;
                    let cached_bytes = safe_bundles(&state.doc, &cached)?;
                    Some((loose, loose_bytes, cached, cached_bytes))
                })
            };
            let (commits, cached, accepted_hashes) = match fragment_path {
                Some((loose, loose_bytes, cached, cached_bytes)) => {
                    let accepted_hashes = loose
                        .iter()
                        .chain(cached.iter())
                        .map(|f| f.head)
                        .collect::<Vec<_>>();
                    let commits = loose
                        .into_iter()
                        .zip(loose_bytes)
                        .map(|(f, bytes)| {
                            let blob = Blob::new(bytes);
                            let commit = LooseCommit::new(
                                sid,
                                CommitId::new(f.head.0),
                                f.boundary.iter().map(|h| CommitId::new(h.0)).collect(),
                                BlobMeta::new(&blob),
                            );
                            (commit, blob)
                        })
                        .collect::<Vec<_>>();
                    let cached = cached
                        .into_iter()
                        .zip(cached_bytes)
                        .map(|(f, bytes)| {
                            let blob = Blob::new(bytes);
                            let boundary: BTreeSet<CommitId> =
                                f.boundary.iter().map(|h| CommitId::new(h.0)).collect();
                            let checkpoints: Vec<CommitId> =
                                f.checkpoints.iter().map(|h| CommitId::new(h.0)).collect();
                            let fragment = Fragment::new(
                                sid,
                                CommitId::new(f.head.0),
                                boundary,
                                &checkpoints,
                                BlobMeta::new(&blob),
                            );
                            (fragment, blob)
                        })
                        .collect::<Vec<_>>();
                    (commits, cached, accepted_hashes)
                }
                None => {
                    state.fragments_unavailable = true;
                    // fragments() panicked: ship each new raw change as its
                    // own loose commit (level-0 fragments are single changes)
                    tracing::warn!(
                        doc = %id.to_url(),
                        "fragments() unavailable; falling back to raw changes"
                    );
                    let changes = state
                        .doc
                        .get_changes(&[])
                        .into_iter()
                        .filter(|c| !state.known.contains(&c.hash()))
                        .collect::<Vec<_>>();
                    let accepted_hashes = changes.iter().map(|c| c.hash()).collect::<Vec<_>>();
                    let commits = changes
                        .into_iter()
                        .map(|c| {
                            let blob = Blob::new(c.raw_bytes().to_vec());
                            let commit = LooseCommit::new(
                                sid,
                                CommitId::new(c.hash().0),
                                c.deps().iter().map(|h| CommitId::new(h.0)).collect(),
                                BlobMeta::new(&blob),
                            );
                            (commit, blob)
                        })
                        .collect::<Vec<_>>();
                    (commits, Vec::new(), accepted_hashes)
                }
            };
            (commits, cached, accepted_hashes)
        };

        if new_commits.is_empty() && new_cached.is_empty() {
            return Ok(());
        }

        self.core
            .store_built_batch(sid, new_commits, new_cached)
            .await
            .map_err(|e| anyhow!("store_built_batch failed: {e}"))?;

        let mut docs = self.docs.lock().await;
        if let Some(state) = docs.get_mut(&id) {
            state.known.extend(accepted_hashes);
        }

        Ok(())
    }

    fn sync_in_background(self: &Arc<Self>, id: DocId) {
        if !self.is_connected() {
            return;
        }
        let repo = self.clone();
        tokio::spawn(async move {
            let _ = repo
                .core
                .sync_with_all_peers(id.sedimentree_id(), true, SYNC_TIMEOUT)
                .await;
        });
    }

    async fn schedule_save_doc(self: &Arc<Self>, id: DocId) {
        if let Some(handle) = self.pending_saves.lock().await.remove(&id) {
            handle.abort();
        }
        let repo = self.clone();
        let handle = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(90)).await;
            repo.pending_saves.lock().await.remove(&id);
            if let Err(e) = repo.save_doc_now(id).await {
                tracing::warn!(doc = %id.to_url(), error = %e, "deferred save failed");
                return;
            }
            repo.sync_in_background(id);
        });
        self.pending_saves.lock().await.insert(id, handle);
    }

    /// Load a doc from local storage into memory (if not already tracked) and
    /// kick off a network sync + subscription in the background.
    pub async fn ensure_doc(self: &Arc<Self>, id: DocId) -> Result<()> {
        {
            let mut docs = self.docs.lock().await;
            if !docs.contains_key(&id) {
                let mut doc = Automerge::new();
                if let Ok(Some(blobs)) = self.core.get_blobs(id.sedimentree_id()).await {
                    for blob in blobs.iter() {
                        let _ = doc.load_incremental(blob.as_slice());
                    }
                }
                let (known, fragments_unavailable) = known_hashes(&doc, false);
                docs.insert(
                    id,
                    DocState {
                        doc,
                        known,
                        fragments_unavailable,
                    },
                );
                let _ = self.events.send(RepoEvent::DocChanged(id));
            }
        }
        let repo = self.clone();
        tokio::spawn(async move {
            repo.wait_connected(Duration::from_secs(15)).await;
            let short = &id.to_url()[11..23];
            for attempt in 0..HEAL_MAX_ATTEMPTS {
                if attempt > 0 {
                    tokio::time::sleep(HEAL_DELAY).await;
                    if !repo.is_connected() {
                        repo.wait_connected(Duration::from_secs(15)).await;
                    }
                }
                let ok = match repo
                    .core
                    .sync_with_all_peers(id.sedimentree_id(), true, SYNC_TIMEOUT)
                    .await
                {
                    Ok(_) => true,
                    Err(e) => {
                        tracing::warn!(error = %e, "sync failed");
                        let _ = repo.events.send(RepoEvent::SyncEvent(format!(
                            "{short}: sync failed: {e}"
                        )));
                        false
                    }
                };
                repo.apply_from_storage(id).await;
                if repo.doc_has_heads(id).await {
                    break;
                }
                if ok {
                    break;
                }
            }
        });
        Ok(())
    }

    async fn doc_has_heads(&self, id: DocId) -> bool {
        self.docs
            .lock()
            .await
            .get(&id)
            .map(|s| !s.doc.get_heads().is_empty())
            .unwrap_or(false)
    }

    /// Block until a doc has content (or the timeout passes). Used when
    /// opening a doc we've never seen locally.
    pub async fn wait_for_doc(self: &Arc<Self>, id: DocId, timeout: Duration) -> bool {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            {
                let docs = self.docs.lock().await;
                if let Some(state) = docs.get(&id) {
                    if !state.doc.get_heads().is_empty() {
                        return true;
                    }
                }
            }
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(150)).await;
        }
    }

    pub async fn create_doc<F>(self: &Arc<Self>, init: F) -> Result<DocId>
    where
        F: FnOnce(&mut Automerge) -> Result<()>,
    {
        let id = DocId::random();
        let mut doc = Automerge::new();
        init(&mut doc)?;
        self.docs.lock().await.insert(
            id,
            DocState {
                doc,
                known: HashSet::new(),
                fragments_unavailable: false,
            },
        );
        self.save_doc(id).await?;
        let repo = self.clone();
        tokio::spawn(async move {
            repo.wait_connected(Duration::from_secs(15)).await;
            if let Err(e) = repo
                .core
                .sync_with_all_peers(id.sedimentree_id(), true, SYNC_TIMEOUT)
                .await
            {
                tracing::warn!(error = %e, "sync of new doc failed");
            }
        });
        Ok(id)
    }

    /// Run a mutation against a tracked doc, then persist + broadcast the
    /// resulting commits. Returns the mutation's value.
    pub async fn change_doc<F, T>(self: &Arc<Self>, id: DocId, f: F) -> Result<T>
    where
        F: FnOnce(&mut Automerge) -> Result<T>,
    {
        if !self.docs.lock().await.contains_key(&id) {
            self.ensure_doc(id).await?;
        }
        let value = {
            let mut docs = self.docs.lock().await;
            let state = docs
                .get_mut(&id)
                .ok_or_else(|| anyhow!("unknown doc {}", id.to_url()))?;
            f(&mut state.doc)?
        };
        self.save_doc(id).await?;
        self.sync_in_background(id);
        Ok(value)
    }

    /// Run a mutation against a fork at `heads`, then merge that fork back into
    /// the current document before saving. This mirrors Automerge JS `changeAt`:
    /// indexes from the rendered editor view are interpreted against the heads
    /// that view actually saw.
    pub async fn change_doc_at<F, T>(
        self: &Arc<Self>,
        id: DocId,
        heads: Vec<ChangeHash>,
        f: F,
    ) -> Result<T>
    where
        F: FnOnce(&mut Automerge) -> Result<T>,
    {
        let value = {
            let mut docs = self.docs.lock().await;
            let state = docs
                .get_mut(&id)
                .ok_or_else(|| anyhow!("unknown doc {}", id.to_url()))?;
            if state.doc.get_heads() == heads {
                f(&mut state.doc)?
            } else {
                let mut fork = state.doc.fork_at(&heads)?;
                let before = fork.get_heads();
                let value = f(&mut fork)?;
                if fork.get_heads() != before {
                    state.doc.merge(&mut fork)?;
                }
                value
            }
        };
        self.save_doc(id).await?;
        self.sync_in_background(id);
        Ok(value)
    }

    /// Like `change_doc_at`, but persistence is debounced. This is for editor
    /// keystroke patches where the in-memory doc must advance immediately but
    /// sedimentree fragment building should not block every character.
    pub async fn change_doc_at_deferred_save<F, T>(
        self: &Arc<Self>,
        id: DocId,
        heads: Vec<ChangeHash>,
        f: F,
    ) -> Result<T>
    where
        F: FnOnce(&mut Automerge) -> Result<T>,
    {
        let value = {
            let mut docs = self.docs.lock().await;
            let state = docs
                .get_mut(&id)
                .ok_or_else(|| anyhow!("unknown doc {}", id.to_url()))?;
            if heads.is_empty() || state.doc.get_heads() == heads {
                f(&mut state.doc)?
            } else {
                let mut fork = state.doc.fork_at(&heads)?;
                let before = fork.get_heads();
                let value = f(&mut fork)?;
                if fork.get_heads() != before {
                    state.doc.merge(&mut fork)?;
                }
                value
            }
        };
        self.schedule_save_doc(id).await;
        Ok(value)
    }

    pub async fn read_doc<F, T>(&self, id: DocId, f: F) -> Result<T>
    where
        F: FnOnce(&Automerge) -> Result<T>,
    {
        let docs = self.docs.lock().await;
        let state = docs
            .get(&id)
            .ok_or_else(|| anyhow!("unknown doc {}", id.to_url()))?;
        f(&state.doc)
    }

    /// Remove a doc from in-memory tracking so the next `ensure_doc` call
    /// reloads from storage and re-syncs. Useful when in-memory state is stuck.
    pub async fn drop_doc(&self, id: DocId) {
        self.docs.lock().await.remove(&id);
    }

    /// One-shot: sync a doc and wait for the server to hold our heads.
    pub async fn flush(&self, id: DocId) -> Result<()> {
        if !self.wait_connected(Duration::from_secs(15)).await {
            return Err(anyhow!("not connected to sync server"));
        }
        self.core
            .sync_with_all_peers(id.sedimentree_id(), true, SYNC_TIMEOUT)
            .await
            .map_err(|e| anyhow!("sync failed: {e}"))?;
        Ok(())
    }

    /// Flush all pending saves and do a best-effort final sync before the app
    /// exits. Should be called from applicationWillTerminate / sceneDidDisconnect.
    pub async fn shutdown(self: &Arc<Self>) {
        let pending: Vec<(DocId, JoinHandle<()>)> = {
            let mut saves = self.pending_saves.lock().await;
            saves.drain().collect()
        };
        for (_, handle) in &pending {
            handle.abort();
        }
        for (id, _) in pending {
            let _ = self.save_doc_now(id).await;
        }
        if !self.is_connected() {
            return;
        }
        let ids: Vec<DocId> = self.docs.lock().await.keys().copied().collect();
        for id in ids {
            let _ = self
                .core
                .sync_with_all_peers(id.sedimentree_id(), true, SYNC_TIMEOUT)
                .await;
        }
    }
}
