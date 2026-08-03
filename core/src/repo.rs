use std::{
    collections::{BTreeSet, HashMap, HashSet},
    future::IntoFuture,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use automerge::{Automerge, ChangeHash, ReadDoc};
use future_form::Sendable;
use sedimentree_core::{
    blob::{Blob, BlobMeta},
    collections::Map,
    crypto::digest::Digest,
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
const SHUTDOWN_SYNC_TIMEOUT: CallTimeout = CallTimeout::TimeoutMillis(5_000);
const SAVE_DEBOUNCE: Duration = Duration::from_millis(90);
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

fn short(id: DocId) -> String {
    id.to_url()[11..23].to_string()
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
    applied: HashSet<Digest<Blob>>,
}

impl DocState {
    fn new(doc: Automerge) -> Self {
        DocState {
            doc,
            known: HashSet::new(),
            applied: HashSet::new(),
        }
    }
}

/// One sync round per doc at a time. A request arriving while a round runs
/// schedules exactly one more round after it, so bursts collapse.
#[derive(Default)]
struct SyncSlot {
    running: bool,
    again: bool,
}

pub struct Repo {
    core: Arc<Core>,
    signer: MemorySigner,
    server_url: String,
    docs: Mutex<HashMap<DocId, DocState>>,
    syncs: Mutex<HashMap<DocId, SyncSlot>>,
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

struct Ingested {
    commits: Vec<(LooseCommit, Blob)>,
    fragments: Vec<(Fragment, Blob)>,
    heads: Vec<ChangeHash>,
}

/// Decompose the doc's automerge fragments into sedimentree records, skipping
/// anything already in `known`. Level 0 becomes loose commits, level 1+ become
/// fragments; filtering happens before bundling so a save only pays to encode
/// what it is about to store.
///
/// `Automerge::fragments` can panic on some change graphs (an upstream bug
/// where a level-1 change escapes the cached fragment clock). A panic means no
/// ingest this round; the next save retries.
fn ingest(doc: &Automerge, sid: SedimentreeId, known: &HashSet<ChangeHash>) -> Option<Ingested> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut out = Ingested {
            commits: Vec::new(),
            fragments: Vec::new(),
            heads: Vec::new(),
        };
        for f in doc.fragments(0..) {
            if known.contains(&f.head) {
                continue;
            }
            let head = f.head;
            let level = f.level;
            let boundary: BTreeSet<CommitId> =
                f.boundary.iter().map(|h| CommitId::new(h.0)).collect();
            let checkpoints: Vec<CommitId> =
                f.checkpoints.iter().map(|h| CommitId::new(h.0)).collect();
            // bundle_fragments silently drops what it cannot encode, so bundle
            // one at a time: a batch call would shift bytes onto the wrong
            // fragment.
            let Some(bytes) = doc.bundle_fragments([f]).into_iter().next() else {
                tracing::warn!(?head, "fragment failed to bundle; retrying on next save");
                continue;
            };
            let blob = Blob::new(bytes);
            let meta = BlobMeta::new(&blob);
            let id = CommitId::new(head.0);
            if level == 0 {
                out.commits
                    .push((LooseCommit::new(sid, id, boundary, meta), blob));
            } else {
                out.fragments
                    .push((Fragment::new(sid, id, boundary, &checkpoints, meta), blob));
            }
            out.heads.push(head);
        }
        out
    }))
    .ok()
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
            syncs: Mutex::new(HashMap::new()),
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
            self.request_sync(id).await;
        }
    }

    async fn on_remote_heads(self: &Arc<Self>, sid: SedimentreeId, heads: Vec<CommitId>) {
        let id = DocId::from_sedimentree_id(sid);
        let hashes: Vec<ChangeHash> = heads.iter().map(|h| ChangeHash(*h.as_bytes())).collect();
        let missing = {
            let docs = self.docs.lock().await;
            let Some(state) = docs.get(&id) else { return };
            !state.doc.get_missing_deps(&hashes).is_empty()
        };
        if !missing {
            return;
        }
        let _ = self.events.send(RepoEvent::SyncEvent(format!(
            "{}: server has heads we're missing — pulling",
            short(id)
        )));
        self.request_sync(id).await;
    }

    /// Run one sync round and apply whatever it landed in local storage.
    async fn sync_once(&self, id: DocId) -> bool {
        match self
            .core
            .sync_with_all_peers(id.sedimentree_id(), true, SYNC_TIMEOUT)
            .await
        {
            Ok(_) => {
                self.apply_new_blobs(id).await;
                true
            }
            Err(e) => {
                tracing::warn!(doc = %id.to_url(), error = %e, "sync failed");
                let _ = self.events.send(RepoEvent::SyncEvent(format!(
                    "{}: sync failed: {e}",
                    short(id)
                )));
                false
            }
        }
    }

    /// Ask for a sync round without waiting for it. Every background path goes
    /// through here so concurrent requests coalesce per doc.
    async fn request_sync(self: &Arc<Self>, id: DocId) {
        if !self.is_connected() {
            return;
        }
        {
            let mut syncs = self.syncs.lock().await;
            let slot = syncs.entry(id).or_default();
            if slot.running {
                slot.again = true;
                return;
            }
            slot.running = true;
        }
        let repo = self.clone();
        tokio::spawn(async move {
            loop {
                repo.sync_once(id).await;
                let mut syncs = repo.syncs.lock().await;
                let slot = syncs.entry(id).or_default();
                if !slot.again {
                    slot.running = false;
                    return;
                }
                slot.again = false;
            }
        });
    }

    /// Bring the in-memory doc up to date with local storage. The first pass
    /// for a doc reads every blob at once; later passes read only the blobs
    /// whose digests have not been applied yet. Returns true (and emits
    /// DocChanged) if the doc advanced.
    async fn apply_new_blobs(&self, id: DocId) -> bool {
        let sid = id.sedimentree_id();
        let commits = self.core.get_commits(sid).await.unwrap_or_default();
        let fragments = self.core.get_fragments(sid).await.unwrap_or_default();

        let (cold, wanted, heads) = {
            let docs = self.docs.lock().await;
            let Some(state) = docs.get(&id) else { return false };
            let heads: Vec<ChangeHash> = fragments
                .iter()
                .map(|f| ChangeHash(*f.head().as_bytes()))
                .chain(commits.iter().map(|c| ChangeHash(*c.head().as_bytes())))
                .collect();
            let wanted: Vec<Digest<Blob>> = fragments
                .iter()
                .map(|f| f.summary().blob_meta().digest())
                .chain(commits.iter().map(|c| c.blob_meta().digest()))
                .filter(|d| !state.applied.contains(d))
                .collect();
            (state.applied.is_empty(), wanted, heads)
        };

        let blobs = if wanted.is_empty() {
            Vec::new()
        } else if cold {
            self.load_all_blobs(sid).await
        } else {
            let mut out = Vec::with_capacity(wanted.len());
            for digest in wanted {
                match self.core.get_blob(sid, digest).await {
                    Ok(Some(blob)) => out.push((digest, blob)),
                    Ok(None) => tracing::warn!(%digest, "no blob for known metadata"),
                    Err(e) => tracing::warn!(error = %e, "get_blob failed"),
                }
            }
            out
        };

        let count = blobs.len();
        let (mut advanced, errors, dangling) = {
            let mut docs = self.docs.lock().await;
            let Some(state) = docs.get_mut(&id) else {
                return false;
            };
            state.known.extend(heads);
            let before = state.doc.get_heads();
            let mut errors = 0u32;
            for (digest, blob) in blobs {
                match state.doc.load_incremental(blob.as_slice()) {
                    Ok(_) => {
                        state.applied.insert(digest);
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "load_incremental failed");
                        errors += 1;
                    }
                }
            }
            (
                state.doc.get_heads() != before,
                errors,
                !state.doc.get_missing_deps(&[]).is_empty(),
            )
        };

        // Changes are queued on deps we never applied. The minimized tree the
        // metadata came from may be hiding a blob raw storage still holds, so
        // fall back to reading everything. Only worth doing when this round
        // brought in something new and did not already read the whole store.
        if dangling && !cold && count > 0 {
            let recovered = self.load_all_blobs(sid).await;
            let mut docs = self.docs.lock().await;
            if let Some(state) = docs.get_mut(&id) {
                let before = state.doc.get_heads();
                for (digest, blob) in recovered {
                    if state.doc.load_incremental(blob.as_slice()).is_ok() {
                        state.applied.insert(digest);
                    }
                }
                advanced = advanced || state.doc.get_heads() != before;
            }
        }

        if errors > 0 {
            let _ = self.events.send(RepoEvent::SyncEvent(format!(
                "{}: {errors}/{count} blobs failed to apply",
                short(id)
            )));
        }
        if !advanced {
            return false;
        }
        let _ = self.events.send(RepoEvent::SyncEvent(format!(
            "{}: doc advanced, {count} new blobs",
            short(id)
        )));
        let _ = self.events.send(RepoEvent::DocChanged(id));
        true
    }

    async fn load_all_blobs(&self, sid: SedimentreeId) -> Vec<(Digest<Blob>, Blob)> {
        match self.core.get_blobs(sid).await {
            Ok(Some(blobs)) => blobs
                .into_iter()
                .map(|b| (BlobMeta::new(&b).digest(), b))
                .collect(),
            Ok(None) => Vec::new(),
            Err(e) => {
                tracing::warn!(error = %e, "get_blobs failed");
                Vec::new()
            }
        }
    }

    /// Push any automerge fragments not yet in the sedimentree. Returns true if
    /// anything was stored.
    async fn save_doc(&self, id: DocId) -> Result<bool> {
        if let Some(handle) = self.pending_saves.lock().await.remove(&id) {
            handle.abort();
        }
        self.save_doc_now(id).await
    }

    async fn save_doc_now(&self, id: DocId) -> Result<bool> {
        let sid = id.sedimentree_id();
        let ingested = {
            let docs = self.docs.lock().await;
            let state = docs
                .get(&id)
                .ok_or_else(|| anyhow!("unknown doc {}", id.to_url()))?;
            ingest(&state.doc, sid, &state.known)
        };
        let Some(ingested) = ingested else {
            tracing::warn!(doc = %id.to_url(), "fragment ingest failed; retrying on next save");
            return Ok(false);
        };
        if ingested.commits.is_empty() && ingested.fragments.is_empty() {
            return Ok(false);
        }

        self.core
            .store_built_batch(sid, ingested.commits, ingested.fragments)
            .await
            .map_err(|e| anyhow!("store_built_batch failed: {e}"))?;

        let mut docs = self.docs.lock().await;
        if let Some(state) = docs.get_mut(&id) {
            state.known.extend(ingested.heads);
        }

        Ok(true)
    }

    async fn schedule_save_doc(self: &Arc<Self>, id: DocId) {
        if let Some(handle) = self.pending_saves.lock().await.remove(&id) {
            handle.abort();
        }
        let repo = self.clone();
        let handle = tokio::spawn(async move {
            tokio::time::sleep(SAVE_DEBOUNCE).await;
            repo.pending_saves.lock().await.remove(&id);
            match repo.save_doc_now(id).await {
                Ok(true) => repo.request_sync(id).await,
                Ok(false) => {}
                Err(e) => tracing::warn!(doc = %id.to_url(), error = %e, "deferred save failed"),
            }
        });
        self.pending_saves.lock().await.insert(id, handle);
    }

    /// Load a doc from local storage into memory (if not already tracked) and
    /// kick off a network sync + subscription in the background. A doc that is
    /// still empty after a sync is retried until it has content.
    pub async fn ensure_doc(self: &Arc<Self>, id: DocId) -> Result<()> {
        let fresh = {
            let mut docs = self.docs.lock().await;
            let fresh = !docs.contains_key(&id);
            if fresh {
                docs.insert(id, DocState::new(Automerge::new()));
            }
            fresh
        };
        if fresh {
            if !self.apply_new_blobs(id).await {
                let _ = self
                    .events
                    .send(RepoEvent::SyncEvent(format!("{}: storage empty on open", short(id))));
            }
            let _ = self.events.send(RepoEvent::DocChanged(id));
        }
        let repo = self.clone();
        tokio::spawn(async move {
            if !repo.wait_connected(Duration::from_secs(15)).await {
                return;
            }
            if repo.doc_has_heads(id).await {
                repo.request_sync(id).await;
                return;
            }
            for attempt in 0..HEAL_MAX_ATTEMPTS {
                if attempt > 0 {
                    tokio::time::sleep(HEAL_DELAY).await;
                    if !repo.is_connected() && !repo.wait_connected(Duration::from_secs(15)).await {
                        return;
                    }
                }
                if !repo.sync_once(id).await || repo.doc_has_heads(id).await {
                    return;
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
        self.docs.lock().await.insert(id, DocState::new(doc));
        self.save_doc(id).await?;
        let repo = self.clone();
        tokio::spawn(async move {
            if repo.wait_connected(Duration::from_secs(15)).await {
                repo.request_sync(id).await;
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
        if self.save_doc(id).await? {
            self.request_sync(id).await;
        }
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
        if self.save_doc(id).await? {
            self.request_sync(id).await;
        }
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
        self.syncs.lock().await.remove(&id);
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
        let mut dirty: HashSet<DocId> = HashSet::new();
        for (id, _) in pending {
            match self.save_doc_now(id).await {
                Ok(true) => {
                    dirty.insert(id);
                }
                Ok(false) => {}
                Err(e) => tracing::warn!(doc = %id.to_url(), error = %e, "shutdown save failed"),
            }
        }
        dirty.extend(
            self.syncs
                .lock()
                .await
                .iter()
                .filter(|(_, slot)| slot.running || slot.again)
                .map(|(id, _)| *id),
        );
        if dirty.is_empty() || !self.is_connected() {
            return;
        }
        futures::future::join_all(dirty.into_iter().map(|id| {
            let core = self.core.clone();
            async move {
                let _ = core
                    .sync_with_all_peers(id.sedimentree_id(), true, SHUTDOWN_SYNC_TIMEOUT)
                    .await;
            }
        }))
        .await;
    }
}
