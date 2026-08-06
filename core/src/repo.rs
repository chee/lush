use std::{
    collections::{BTreeSet, HashMap, HashSet},
    future::IntoFuture,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use async_tungstenite::{
    tokio::TokioAdapter,
    tungstenite::{handshake::server::NoCallback, protocol::WebSocketConfig},
};
use automerge::{Automerge, ChangeHash, Fragment as AutomergeFragment, ReadDoc};
use future_form::Sendable;
use futures::{future::BoxFuture, FutureExt};
use sedimentree_core::{
    blob::{Blob, BlobMeta},
    collections::Map,
    crypto::digest::Digest,
    depth::CountLeadingZeroBytes,
    fragment::Fragment as SedimentreeFragment,
    id::SedimentreeId,
    loose_commit::{id::CommitId, LooseCommit},
    sedimentree::{Sedimentree, SedimentreeItem},
};
use sedimentree_fs_storage::FsStorage;
use subduction_core::{
    collections::bounded_sharded_map::BoundedShardedMap,
    connection::message::SyncMessage,
    handler::sync::SyncHandler,
    handshake::{
        self,
        audience::{Audience, DiscoveryId},
    },
    nonce_cache::NonceCache,
    peer::id::PeerId,
    policy::open::OpenPolicy,
    remote_heads::{RemoteHeads, RemoteHeadsObserver},
    storage::{powerbox::StoragePowerbox, traits::Storage},
    subduction::Subduction,
    timeout::call::CallTimeout,
    timestamp::TimestampSeconds,
    transport::{message::MessageTransport, Transport},
};
use subduction_crypto::{signed::Signed, signer::memory::MemorySigner};
use subduction_ephemeral::{
    clock::std_clock::StdClock,
    composed::ComposedHandler,
    config::EphemeralConfig,
    handler::EphemeralHandler,
    message::{EphemeralMessage, EphemeralPayload},
    policy::OpenEphemeralPolicy,
    topic::Topic,
};
use subduction_http_longpoll::{server::LongPollHandler, transport::HttpLongPollTransport};
use subduction_iroh::transport::IrohTransport;
use subduction_websocket::timeout::FuturesTimerTimeout;
use subduction_websocket::{
    handshake::WebSocketHandshake,
    sleep::TokioSleeper,
    tokio::{client::TokioWebSocketClient, TimeoutTokio, TokioSpawn},
    websocket::{KeepAlive, WebSocket},
    DEFAULT_MAX_MESSAGE_SIZE,
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{broadcast, mpsc, Mutex},
    task::JoinHandle,
};

use crate::{
    observed_storage::{ObservedStorage, StoredBatch, StoredRecord},
    wire::WireMessage,
};

pub const DEFAULT_SERVER: &str = "wss://subduction.sync.inkandswitch.com";

const SYNC_TIMEOUT: CallTimeout = CallTimeout::TimeoutMillis(30_000);
const SHUTDOWN_SYNC_TIMEOUT: CallTimeout = CallTimeout::TimeoutMillis(5_000);
const SAVE_DEBOUNCE: Duration = Duration::from_millis(90);
const HEAL_DELAY: Duration = Duration::from_secs(5);
const HEAL_MAX_ATTEMPTS: u32 = 12;
const LOCAL_SERVER_PORT: u16 = 43219;
const HANDSHAKE_MAX_DRIFT: Duration = Duration::from_secs(600);
const LOOSE_FRAGMENT_BATCH_SIZE: usize = 32;

/// A local-peer WebSocket transport that intercepts incoming BatchSyncRequests
/// and pre-fetches unknown docs from the remote server before letting the
/// SyncHandler process the message. This prevents automerge-repo from seeing
/// an empty sync response and immediately marking the doc "unavailable".
///
/// The repo reference is held outside this type (in a spawned task) to avoid
/// a recursive type-parameter cycle that would make the Sync bound overflow.
#[derive(Debug, Clone)]
pub struct PrefetchTransport {
    inner: WebSocket<TokioAdapter<TcpStream>, Sendable>,
    prefetch_tx: mpsc::UnboundedSender<(SedimentreeId, tokio::sync::oneshot::Sender<()>)>,
}

impl PartialEq for PrefetchTransport {
    fn eq(&self, other: &Self) -> bool {
        self.inner == other.inner
    }
}

/// One Subduction node carries the dialed connection to the public server,
/// websocket peers accepted on the loopback listener (patchwork webviews),
/// iroh QUIC peers for direct device-to-device sync,
/// and HTTP long-poll peers for Pushwork compatibility.
#[derive(Debug, Clone)]
pub enum WsTransport {
    Dialed(TokioWebSocketClient<MemorySigner>),
    Accepted(WebSocket<TokioAdapter<TcpStream>, Sendable>),
    Iroh(IrohTransport),
    HttpLongPoll(HttpLongPollTransport),
    Prefetch(PrefetchTransport),
}

#[derive(Debug, Clone, Copy, thiserror::Error)]
pub enum TransportSendError {
    #[error("{0}")]
    Ws(subduction_websocket::error::SendError),
    #[error("{0}")]
    Iroh(subduction_iroh::error::SendError),
    #[error("{0}")]
    Http(subduction_http_longpoll::error::SendError),
}

#[derive(Debug, Clone, Copy, thiserror::Error)]
pub enum TransportRecvError {
    #[error("{0}")]
    Ws(subduction_websocket::error::RecvError),
    #[error("{0}")]
    Iroh(subduction_iroh::error::RecvError),
    #[error("{0}")]
    Http(subduction_http_longpoll::error::RecvError),
}

#[derive(Debug, Clone, Copy, thiserror::Error)]
pub enum TransportDisconnectError {
    #[error("{0}")]
    Ws(subduction_websocket::error::DisconnectionError),
    #[error("{0}")]
    Iroh(subduction_iroh::error::DisconnectionError),
    #[error("{0}")]
    Http(subduction_http_longpoll::error::DisconnectionError),
}

impl Transport<Sendable> for WsTransport {
    type SendError = TransportSendError;
    type RecvError = TransportRecvError;
    type DisconnectionError = TransportDisconnectError;

    fn send_bytes(&self, bytes: &[u8]) -> BoxFuture<'_, Result<(), Self::SendError>> {
        match self {
            Self::Dialed(ws) => {
                let fut = Transport::<Sendable>::send_bytes(ws, bytes);
                Box::pin(async move { fut.await.map_err(TransportSendError::Ws) })
            }
            Self::Accepted(ws) => {
                let fut = Transport::<Sendable>::send_bytes(ws, bytes);
                Box::pin(async move { fut.await.map_err(TransportSendError::Ws) })
            }
            Self::Prefetch(pt) => {
                let fut = Transport::<Sendable>::send_bytes(&pt.inner, bytes);
                Box::pin(async move { fut.await.map_err(TransportSendError::Ws) })
            }
            Self::Iroh(iroh) => {
                let fut = Transport::<Sendable>::send_bytes(iroh, bytes);
                Box::pin(async move { fut.await.map_err(TransportSendError::Iroh) })
            }
            Self::HttpLongPoll(lp) => {
                let fut = Transport::<Sendable>::send_bytes(lp, bytes);
                Box::pin(async move { fut.await.map_err(TransportSendError::Http) })
            }
        }
    }

    fn recv_bytes(&self) -> BoxFuture<'_, Result<Vec<u8>, Self::RecvError>> {
        match self {
            Self::Dialed(ws) => Transport::<Sendable>::recv_bytes(ws)
                .map(|r| r.map_err(TransportRecvError::Ws))
                .boxed(),
            Self::Accepted(ws) => Transport::<Sendable>::recv_bytes(ws)
                .map(|r| r.map_err(TransportRecvError::Ws))
                .boxed(),
            Self::Prefetch(pt) => {
                let inner = pt.inner.clone();
                let prefetch_tx = pt.prefetch_tx.clone();
                async move {
                    let bytes = match Transport::<Sendable>::recv_bytes(&inner).await {
                        Ok(b) => b,
                        Err(e) => {
                            return Err(TransportRecvError::Ws(e));
                        }
                    };
                    if let Ok(SyncMessage::BatchSyncRequest(req)) = SyncMessage::try_decode(&bytes)
                    {
                        if req.subscribe {
                            let (done_tx, done_rx) = tokio::sync::oneshot::channel::<()>();
                            if prefetch_tx.send((req.id, done_tx)).is_ok() {
                                let _ =
                                    tokio::time::timeout(Duration::from_secs(30), done_rx).await;
                            }
                        }
                    }
                    Ok(bytes)
                }
                .boxed()
            }
            Self::Iroh(iroh) => Transport::<Sendable>::recv_bytes(iroh)
                .map(|r| r.map_err(TransportRecvError::Iroh))
                .boxed(),
            Self::HttpLongPoll(lp) => Transport::<Sendable>::recv_bytes(lp)
                .map(|r| r.map_err(TransportRecvError::Http))
                .boxed(),
        }
    }

    fn disconnect(&self) -> BoxFuture<'_, Result<(), Self::DisconnectionError>> {
        match self {
            Self::Dialed(ws) => Transport::<Sendable>::disconnect(ws)
                .map(|r| r.map_err(TransportDisconnectError::Ws))
                .boxed(),
            Self::Accepted(ws) => Transport::<Sendable>::disconnect(ws)
                .map(|r| r.map_err(TransportDisconnectError::Ws))
                .boxed(),
            Self::Prefetch(pt) => Transport::<Sendable>::disconnect(&pt.inner)
                .map(|r| r.map_err(TransportDisconnectError::Ws))
                .boxed(),
            Self::Iroh(iroh) => Transport::<Sendable>::disconnect(iroh)
                .map(|r| r.map_err(TransportDisconnectError::Iroh))
                .boxed(),
            Self::HttpLongPoll(lp) => Transport::<Sendable>::disconnect(lp)
                .map(|r| r.map_err(TransportDisconnectError::Http))
                .boxed(),
        }
    }
}

impl PartialEq for WsTransport {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Dialed(a), Self::Dialed(b)) => a == b,
            (Self::Accepted(a), Self::Accepted(b)) => a == b,
            (Self::Prefetch(a), Self::Prefetch(b)) => a == b,
            (Self::Iroh(a), Self::Iroh(b)) => a == b,
            (Self::HttpLongPoll(a), Self::HttpLongPoll(b)) => a == b,
            _ => false,
        }
    }
}

async fn accept_iroh_peer(
    endpoint: Arc<iroh::Endpoint>,
    node: Arc<Core>,
    signer: MemorySigner,
    peer_id: PeerId,
    ephemeral: EphHandler,
) {
    let nonce_cache = NonceCache::default();
    loop {
        match subduction_iroh::server::accept_one(
            &endpoint,
            &signer,
            &nonce_cache,
            peer_id,
            None,
            HANDSHAKE_MAX_DRIFT,
        )
        .await
        {
            Ok(result) => {
                tokio::spawn(result.listener_task);
                tokio::spawn(result.sender_task);
                let mapped = result
                    .authenticated
                    .map(|c| MessageTransport::new(WsTransport::Iroh(c)));
                let peer = mapped.peer_id();
                if let Err(e) = node.add_connection(mapped).await {
                    tracing::warn!(error = %e, "iroh: add_connection failed");
                } else {
                    ephemeral.subscribe_peer(peer).await;
                }
            }
            Err(subduction_iroh::error::AcceptError::NoIncoming) => break,
            Err(e) => tracing::warn!(error = %e, "iroh: accept failed"),
        }
    }
}

type Conn = MessageTransport<WsTransport>;

async fn accept_local_http_peer(
    tcp: TcpStream,
    node: Arc<Core>,
    lp_handler: LongPollHandler<MemorySigner, FuturesTimerTimeout>,
    ephemeral: EphHandler,
) {
    use http_body_util::Full;
    use hyper::body::Bytes;
    use hyper::header::{
        HeaderValue, ACCESS_CONTROL_ALLOW_HEADERS, ACCESS_CONTROL_ALLOW_METHODS,
        ACCESS_CONTROL_ALLOW_ORIGIN, ACCESS_CONTROL_EXPOSE_HEADERS, ACCESS_CONTROL_MAX_AGE,
    };
    use hyper_util::rt::TokioIo;

    let io = TokioIo::new(tcp);
    let service = hyper::service::service_fn(move |req| {
        let handler = lp_handler.clone();
        let node = node.clone();
        let ephemeral = ephemeral.clone();
        async move {
            if req.method() == hyper::Method::OPTIONS {
                let mut resp = hyper::Response::new(Full::new(Bytes::new()));
                *resp.status_mut() = hyper::StatusCode::NO_CONTENT;
                resp.headers_mut()
                    .insert(ACCESS_CONTROL_ALLOW_ORIGIN, HeaderValue::from_static("*"));
                resp.headers_mut().insert(
                    ACCESS_CONTROL_ALLOW_METHODS,
                    HeaderValue::from_static("POST, OPTIONS"),
                );
                resp.headers_mut().insert(
                    ACCESS_CONTROL_ALLOW_HEADERS,
                    HeaderValue::from_static("Content-Type, X-Session-Id"),
                );
                resp.headers_mut().insert(
                    ACCESS_CONTROL_EXPOSE_HEADERS,
                    HeaderValue::from_static("X-Session-Id"),
                );
                resp.headers_mut()
                    .insert(ACCESS_CONTROL_MAX_AGE, HeaderValue::from_static("86400"));
                return Ok::<_, hyper::Error>(resp);
            }

            let resp = match handler.handle(req).await {
                Ok(r) => r,
                Err(e) => {
                    tracing::error!(error = %e, "http longpoll handler error");
                    hyper::Response::new(Full::new(Bytes::from(e.to_string())))
                }
            };

            if resp.status() == hyper::StatusCode::OK {
                if let Some(sid_hdr) = resp
                    .headers()
                    .get(subduction_http_longpoll::SESSION_ID_HEADER)
                {
                    if let Ok(sid_str) = sid_hdr.to_str() {
                        if let Some(sid) =
                            subduction_http_longpoll::session::SessionId::from_hex(sid_str)
                        {
                            if let Some(auth) = handler.take_authenticated(&sid).await {
                                let mapped = auth
                                    .map(|lp| MessageTransport::new(WsTransport::HttpLongPoll(lp)));
                                let peer = mapped.peer_id();
                                if let Err(e) = node.add_connection(mapped).await {
                                    tracing::warn!(error = %e, "http longpoll: add_connection failed");
                                } else {
                                    ephemeral.subscribe_peer(peer).await;
                                }
                            }
                        }
                    }
                }
            }

            let (mut parts, body) = resp.into_parts();
            parts
                .headers
                .insert(ACCESS_CONTROL_ALLOW_ORIGIN, HeaderValue::from_static("*"));
            parts.headers.insert(
                ACCESS_CONTROL_ALLOW_METHODS,
                HeaderValue::from_static("POST, OPTIONS"),
            );
            parts.headers.insert(
                ACCESS_CONTROL_ALLOW_HEADERS,
                HeaderValue::from_static("Content-Type, X-Session-Id"),
            );
            parts.headers.insert(
                ACCESS_CONTROL_EXPOSE_HEADERS,
                HeaderValue::from_static("X-Session-Id"),
            );
            Ok::<_, hyper::Error>(hyper::Response::from_parts(parts, body))
        }
    });

    let builder =
        hyper_util::server::conn::auto::Builder::new(hyper_util::rt::TokioExecutor::new());
    if let Err(e) = builder.serve_connection(io, service).await {
        tracing::debug!(error = %e, "http longpoll connection ended");
    }
}

async fn accept_local_peer(
    tcp: TcpStream,
    node: Arc<Core>,
    repo: Arc<Repo>,
    server_peer_id: PeerId,
    discovery_audience: Option<Audience>,
) {
    let peer_addr = tcp.peer_addr().ok();
    tracing::info!(?peer_addr, "local peer connecting");
    let mut ws_config = WebSocketConfig::default();
    ws_config.max_message_size = Some(DEFAULT_MAX_MESSAGE_SIZE);

    let ws_stream = match async_tungstenite::tokio::accept_hdr_async_with_config(
        tcp,
        NoCallback,
        Some(ws_config),
    )
    .await
    {
        Ok(ws) => ws,
        Err(_) => return,
    };

    let (prefetch_tx, mut prefetch_rx) =
        mpsc::unbounded_channel::<(SedimentreeId, tokio::sync::oneshot::Sender<()>)>();

    let result = handshake::respond::<Sendable, _, _, _, _>(
        WebSocketHandshake::new(ws_stream),
        |ws_handshake, peer_id| {
            let (ws, sender_fut, keepalive_task) = WebSocket::new_with_keepalive(
                ws_handshake.into_inner(),
                peer_id,
                KeepAlive::balanced(),
                TokioSleeper,
            );
            let listen_ws = ws.clone();
            tokio::spawn(async move {
                let _ = listen_ws.listen().await;
            });
            tokio::spawn(async move {
                let _ = sender_fut.await;
            });
            tokio::spawn(async move {
                let _ = keepalive_task.await;
            });
            let transport = PrefetchTransport {
                inner: ws,
                prefetch_tx: prefetch_tx.clone(),
            };
            (MessageTransport::new(WsTransport::Prefetch(transport)), ())
        },
        node.signer(),
        node.nonce_cache(),
        server_peer_id,
        discovery_audience,
        TimestampSeconds::now(),
        HANDSHAKE_MAX_DRIFT,
    )
    .await;

    let Ok((authenticated, ())) = result else {
        tracing::warn!(?peer_addr, "local peer handshake failed");
        return;
    };
    let peer = authenticated.peer_id();
    let _ = node.add_connection(authenticated).await;
    repo.ephemeral.subscribe_peer(peer).await;

    tokio::spawn(async move {
        while let Some((sid, done_tx)) = prefetch_rx.recv().await {
            let repo = repo.clone();
            tokio::spawn(async move {
                let id = DocId::from_sedimentree_id(sid);
                repo.prefetch_doc(id, Duration::from_secs(30)).await;
                let _ = done_tx.send(());
            });
        }
    });
}
type Handler = SyncHandler<
    Sendable,
    ObservedStorage,
    Conn,
    OpenPolicy,
    CountLeadingZeroBytes,
    TokioSpawn,
    256,
    HeadsObserver,
>;
type EphHandler = EphemeralHandler<Sendable, Conn, OpenEphemeralPolicy, StdClock, TokioSpawn>;
type WireHandler = ComposedHandler<Handler, EphHandler, WireMessage>;
type Core = Subduction<
    'static,
    Sendable,
    ObservedStorage,
    Conn,
    WireHandler,
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
    Ephemeral(DocId, Vec<u8>),
}

#[derive(Debug, Clone)]
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
    stored_commits: HashSet<ChangeHash>,
    stored_fragments: HashSet<ChangeHash>,
    applied: HashSet<Digest<Blob>>,
}

impl DocState {
    fn shared(doc: Automerge) -> Arc<Mutex<Self>> {
        Arc::new(Mutex::new(Self::new(doc)))
    }

    fn new(doc: Automerge) -> Self {
        DocState {
            doc,
            stored_commits: HashSet::new(),
            stored_fragments: HashSet::new(),
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

struct PendingSave {
    generation: u64,
    handle: JoinHandle<()>,
}

pub struct Repo {
    core: Arc<Core>,
    storage: ObservedStorage,
    signer: MemorySigner,
    ephemeral: EphHandler,
    server_url: String,
    /// The outer lock only guards the map. Each doc carries its own lock, so
    /// decoding blobs into one doc or building fragments for it does not stall
    /// reads of every other doc — which is what the UI does on every keystroke.
    docs: Mutex<HashMap<DocId, Arc<Mutex<DocState>>>>,
    syncs: Mutex<HashMap<DocId, SyncSlot>>,
    pending_saves: Mutex<HashMap<DocId, PendingSave>>,
    last_server_heads: Mutex<HashMap<DocId, BTreeSet<CommitId>>>,
    last_synced_local_heads: Mutex<HashMap<DocId, BTreeSet<CommitId>>>,
    next_save: AtomicU64,
    events: broadcast::Sender<RepoEvent>,
    connected: AtomicBool,
    connect_started: AtomicBool,
    local_port: Option<u16>,
    iroh_endpoint: Option<Arc<iroh::Endpoint>>,
}

fn load_or_create_iroh_key(path: &Path) -> Result<iroh::SecretKey> {
    if let Ok(bytes) = std::fs::read(path) {
        if let Ok(arr) = <[u8; 32]>::try_from(bytes.as_slice()) {
            return Ok(iroh::SecretKey::from(arr));
        }
    }
    let key = iroh::SecretKey::generate();
    std::fs::write(path, key.to_bytes()).context("writing iroh key")?;
    Ok(key)
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
    fragments: Vec<(SedimentreeFragment, Blob)>,
    commit_heads: Vec<ChangeHash>,
    fragment_heads: Vec<ChangeHash>,
}

/// Decompose the doc's automerge fragments into sedimentree records, skipping
/// anything already stored. Level 0 commits are batched into fragment records
/// once enough accumulate; the short tail remains loose so small edits still
/// persist immediately.
///
/// `Automerge::fragments` can panic on some change graphs (an upstream bug
/// where a level-1 change escapes the cached fragment clock). A panic means no
/// ingest this round; the next save retries.
fn ingest(
    doc: &Automerge,
    sid: SedimentreeId,
    stored_commits: &HashSet<ChangeHash>,
    stored_fragments: &HashSet<ChangeHash>,
) -> Option<Ingested> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let fragments = doc.fragments(0..);
        let mut out = Ingested {
            commits: Vec::new(),
            fragments: Vec::new(),
            commit_heads: Vec::new(),
            fragment_heads: Vec::new(),
        };
        let mut pending_loose = Vec::new();
        for f in fragments {
            let head = f.head;
            let level = f.level;
            if (level == 0 && stored_commits.contains(&head))
                || (level > 0 && stored_fragments.contains(&head))
            {
                continue;
            }
            if level == 0 {
                pending_loose.push(f);
                if pending_loose.len() >= LOOSE_FRAGMENT_BATCH_SIZE {
                    ingest_loose_batch(doc, sid, &mut pending_loose, stored_fragments, &mut out);
                }
                continue;
            }
            let boundary: BTreeSet<CommitId> =
                f.boundary.iter().map(|h| CommitId::new(h.0)).collect();
            let checkpoints: Vec<CommitId> =
                f.checkpoints.iter().map(|h| CommitId::new(h.0)).collect();
            let Some(bytes) = doc.bundle_fragments([f]).into_iter().next() else {
                tracing::warn!(?head, "fragment failed to bundle; retrying on next save");
                continue;
            };
            let blob = Blob::new(bytes);
            let meta = BlobMeta::new(&blob);
            let id = CommitId::new(head.0);
            out.fragments.push((
                SedimentreeFragment::new(sid, id, boundary, &checkpoints, meta),
                blob,
            ));
            out.fragment_heads.push(head);
        }
        ingest_loose_tail(doc, sid, pending_loose, stored_commits, &mut out);
        out
    }))
    .ok()
}

fn ingest_loose_batch(
    doc: &Automerge,
    sid: SedimentreeId,
    pending: &mut Vec<AutomergeFragment>,
    stored_fragments: &HashSet<ChangeHash>,
    out: &mut Ingested,
) {
    let batch: Vec<_> = pending.drain(..).collect();
    let Some(head) = batch.last().map(|fragment| fragment.head) else {
        return;
    };
    if stored_fragments.contains(&head) {
        return;
    }
    let members: Vec<ChangeHash> = batch.iter().map(|fragment| fragment.head).collect();
    let covered_heads = members.clone();
    let member_set: HashSet<ChangeHash> = members.iter().copied().collect();
    let mut seen_boundary = HashSet::new();
    let boundary: Vec<ChangeHash> = batch
        .iter()
        .flat_map(|fragment| fragment.boundary.iter().copied())
        .filter(|hash| !member_set.contains(hash) && seen_boundary.insert(*hash))
        .collect();
    let checkpoints = members.clone();
    let fragment = AutomergeFragment {
        head,
        level: 0,
        boundary: boundary.clone(),
        checkpoints: checkpoints.clone(),
        members,
    };
    let Some(bytes) = doc.bundle_fragments([fragment]).into_iter().next() else {
        tracing::warn!(
            ?head,
            "loose commit batch failed to bundle; retrying as loose commits"
        );
        return;
    };
    let blob = Blob::new(bytes);
    let meta = BlobMeta::new(&blob);
    let boundary_ids: BTreeSet<CommitId> = boundary
        .into_iter()
        .map(|hash| CommitId::new(hash.0))
        .collect();
    let checkpoint_ids: Vec<CommitId> = checkpoints
        .into_iter()
        .map(|hash| CommitId::new(hash.0))
        .collect();
    out.fragments.push((
        SedimentreeFragment::new(
            sid,
            CommitId::new(head.0),
            boundary_ids,
            &checkpoint_ids,
            meta,
        ),
        blob,
    ));
    out.commit_heads.extend(covered_heads);
    out.fragment_heads.push(head);
}

fn ingest_loose_tail(
    doc: &Automerge,
    sid: SedimentreeId,
    pending: Vec<AutomergeFragment>,
    stored_commits: &HashSet<ChangeHash>,
    out: &mut Ingested,
) {
    for fragment in pending {
        let head = fragment.head;
        if stored_commits.contains(&head) {
            continue;
        }
        let boundary: BTreeSet<CommitId> = fragment
            .boundary
            .iter()
            .map(|h| CommitId::new(h.0))
            .collect();
        let Some(bytes) = doc.bundle_fragments([fragment]).into_iter().next() else {
            tracing::warn!(
                ?head,
                "loose commit failed to bundle; retrying on next save"
            );
            continue;
        };
        let blob = Blob::new(bytes);
        let meta = BlobMeta::new(&blob);
        out.commits.push((
            LooseCommit::new(sid, CommitId::new(head.0), boundary, meta),
            blob,
        ));
        out.commit_heads.push(head);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SyncOutcome {
    NoPeers,
    Succeeded { data_received: bool },
    Failed { data_received: bool },
}

impl SyncOutcome {
    fn data_received(self) -> bool {
        match self {
            SyncOutcome::NoPeers => false,
            SyncOutcome::Succeeded { data_received } | SyncOutcome::Failed { data_received } => {
                data_received
            }
        }
    }
}

fn classify_sync<I>(peers: I) -> SyncOutcome
where
    I: IntoIterator<Item = (bool, bool)>,
{
    let mut count = 0usize;
    let mut succeeded = false;
    let mut data_received = false;
    for (peer_succeeded, peer_received) in peers {
        count += 1;
        succeeded |= peer_succeeded;
        data_received |= peer_received;
    }
    if count == 0 {
        SyncOutcome::NoPeers
    } else if succeeded {
        SyncOutcome::Succeeded { data_received }
    } else {
        SyncOutcome::Failed { data_received }
    }
}

/// Run CPU-heavy automerge work without starving the runtime's worker
/// threads. Falls through on current-thread runtimes (tests).
fn cpu_heavy<T>(f: impl FnOnce() -> T) -> T {
    use tokio::runtime::{Handle, RuntimeFlavor};
    match Handle::try_current() {
        Ok(handle) if handle.runtime_flavor() == RuntimeFlavor::MultiThread => {
            tokio::task::block_in_place(f)
        }
        _ => f(),
    }
}

fn apply_batch_to_state(state: &mut DocState, batch: StoredBatch, id: DocId) -> (bool, bool) {
    state.stored_commits.extend(
        batch
            .commits
            .iter()
            .map(|record| ChangeHash(*record.meta.head().as_bytes())),
    );
    state.stored_fragments.extend(
        batch
            .fragments
            .iter()
            .map(|record| ChangeHash(*record.meta.head().as_bytes())),
    );
    let commits: Vec<_> = batch
        .commits
        .into_iter()
        .filter(|record| {
            !state
                .applied
                .contains(&BlobMeta::new(&record.blob).digest())
        })
        .collect();
    let fragments: Vec<_> = batch
        .fragments
        .into_iter()
        .filter(|record| {
            !state
                .applied
                .contains(&BlobMeta::new(&record.blob).digest())
        })
        .collect();
    if commits.is_empty() && fragments.is_empty() {
        return (false, false);
    }
    let before = state.doc.get_heads();
    match load_blob_batch(&mut state.doc, &commits, &fragments) {
        Ok(applied) => {
            state.applied.extend(applied);
            (state.doc.get_heads() != before, false)
        }
        Err(e) => {
            tracing::warn!(doc = %id.to_url(), error = %e, "stored blobs failed to apply");
            (false, true)
        }
    }
}

/// Apply stored blobs to `doc` in the dependency order guaranteed by their
/// sedimentree fragment metadata.
fn load_blob_batch(
    doc: &mut Automerge,
    commits: &[StoredRecord<LooseCommit>],
    fragments: &[StoredRecord<SedimentreeFragment>],
) -> Result<Vec<Digest<Blob>>> {
    if commits.is_empty() && fragments.is_empty() {
        return Ok(Vec::new());
    }
    let sedimentree = Sedimentree::new(
        fragments.iter().map(|record| record.meta.clone()).collect(),
        commits.iter().map(|record| record.meta.clone()).collect(),
    );
    let fragment_metas: Vec<_> = sedimentree.fragments().collect();
    let commit_metas: Vec<_> = sedimentree.loose_commits().collect();
    let blobs: HashMap<_, _> = commits
        .iter()
        .map(|record| (BlobMeta::new(&record.blob).digest(), &record.blob))
        .chain(
            fragments
                .iter()
                .map(|record| (BlobMeta::new(&record.blob).digest(), &record.blob)),
        )
        .collect();
    let mut digests = Vec::new();
    let mut bytes = Vec::new();
    for item in sedimentree.topsorted_blob_order()? {
        let digest = match item {
            SedimentreeItem::Fragment(index) => {
                fragment_metas[index].summary().blob_meta().digest()
            }
            SedimentreeItem::LooseCommit(index) => commit_metas[index].blob_meta().digest(),
        };
        if digests.contains(&digest) {
            continue;
        }
        let blob = blobs
            .get(&digest)
            .ok_or_else(|| anyhow!("stored metadata has no matching blob {digest}"))?;
        bytes.extend_from_slice(blob.as_slice());
        digests.push(digest);
    }
    doc.load_incremental(&bytes)?;
    Ok(digests)
}

impl Repo {
    pub fn local_server_port(&self) -> Option<u16> {
        self.local_port
    }

    pub fn local_http_url(&self) -> Option<String> {
        self.local_port
            .map(|port| format!("http://127.0.0.1:{port}"))
    }

    pub fn iroh_node_id(&self) -> Option<String> {
        self.iroh_endpoint.as_ref().map(|ep| ep.id().to_string())
    }

    pub async fn add_iroh_peer(self: &Arc<Self>, node_id_str: String) -> Result<()> {
        let ep = self
            .iroh_endpoint
            .as_ref()
            .ok_or_else(|| anyhow!("iroh endpoint not running"))?;
        let node_id: iroh::EndpointId = node_id_str
            .parse()
            .map_err(|e| anyhow!("invalid iroh node id: {e}"))?;
        let addr = iroh::EndpointAddr::from(node_id);
        let audience = Audience::discover(node_id_str.as_bytes());
        let result = subduction_iroh::client::connect(ep, addr, &self.signer, audience).await?;
        let node = self.core.clone();
        tokio::spawn(result.listener_task);
        tokio::spawn(result.sender_task);
        let mapped = result
            .authenticated
            .map(|c| MessageTransport::new(WsTransport::Iroh(c)));
        let peer = mapped.peer_id();
        node.add_connection(mapped)
            .await
            .map_err(|e| anyhow!("add_connection failed: {e}"))?;
        self.ephemeral.subscribe_peer(peer).await;
        tracing::info!(peer = %node_id_str, "iroh: dialed peer");
        Ok(())
    }

    /// Raw stored blobs for a doc, each a loadable automerge chunk. Serves the
    /// webviews' storage read-through; order is irrelevant because automerge
    /// backlogs changes whose dependencies haven't been applied yet.
    pub async fn doc_chunks(&self, id: DocId) -> Vec<(String, Vec<u8>)> {
        let sid = id.sedimentree_id();
        let fragments = <ObservedStorage as Storage<Sendable>>::load_fragments(&self.storage, sid)
            .await
            .unwrap_or_default();
        let commits =
            <ObservedStorage as Storage<Sendable>>::load_loose_commits(&self.storage, sid)
                .await
                .unwrap_or_default();
        let mut chunks = Vec::new();
        for record in &fragments {
            let blob = record.blob();
            chunks.push((
                BlobMeta::new(blob).digest().to_string(),
                blob.as_slice().to_vec(),
            ));
        }
        for record in &commits {
            let blob = record.blob();
            chunks.push((
                BlobMeta::new(blob).digest().to_string(),
                blob.as_slice().to_vec(),
            ));
        }
        chunks
    }

    pub async fn start(data_dir: PathBuf, server_url: String) -> Result<Arc<Repo>> {
        let boot = std::time::Instant::now();
        std::fs::create_dir_all(&data_dir).context("creating data dir")?;
        let iroh_key = load_or_create_iroh_key(&data_dir.join("iroh.key"))?;
        let signer = load_or_create_signer(&data_dir.join("identity.seed"))?;
        let storage =
            FsStorage::new(data_dir.join("sedimentree")).context("opening sedimentree storage")?;
        tracing::info!(
            elapsed_ms = boot.elapsed().as_millis(),
            "repo storage opened"
        );
        let (stored_tx, mut stored_rx) = mpsc::unbounded_channel();
        let (heads_tx, mut heads_rx) = mpsc::unbounded_channel();
        let storage = ObservedStorage::new(storage, stored_tx);

        let sedimentrees = Arc::new(BoundedShardedMap::new());
        let connections = Arc::new(async_lock::Mutex::new(Map::new()));
        let subscriptions = Arc::new(async_lock::Mutex::new(Map::new()));
        let powerbox = StoragePowerbox::new(storage.clone(), Arc::new(OpenPolicy));
        let sync_handler = SyncHandler::with_remote_heads_observer(
            sedimentrees.clone(),
            connections.clone(),
            subscriptions.clone(),
            powerbox.clone(),
            CountLeadingZeroBytes,
            HeadsObserver { tx: heads_tx },
            TokioSpawn,
        );
        let (ephemeral, ephemeral_rx) = EphemeralHandler::new(
            connections.clone(),
            OpenEphemeralPolicy,
            EphemeralConfig::default(),
            StdClock,
            TokioSpawn,
        );
        let handler = Arc::new(ComposedHandler::new(sync_handler, ephemeral.clone()));
        let listener = match TcpListener::bind(("127.0.0.1", LOCAL_SERVER_PORT)).await {
            Ok(l) => Some(l),
            Err(_) => TcpListener::bind(("127.0.0.1", 0)).await.ok(),
        };
        let local_port = listener
            .as_ref()
            .and_then(|l| l.local_addr().ok())
            .map(|addr| addr.port());
        let discovery_id =
            local_port.map(|port| DiscoveryId::new(format!("127.0.0.1:{port}").as_bytes()));
        tracing::info!(
            elapsed_ms = boot.elapsed().as_millis(),
            port = ?local_port,
            "repo local listener bound"
        );

        let send_counter = handler.sync().send_counter().clone();
        let (core, listener_fut, manager_fut) = Subduction::new(
            handler,
            discovery_id,
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
        tracing::info!(
            elapsed_ms = boot.elapsed().as_millis(),
            "repo subduction core ready"
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

        let iroh_endpoint = match iroh::Endpoint::builder(iroh::endpoint::presets::N0)
            .secret_key(iroh_key)
            .alpns(vec![subduction_iroh::ALPN.to_vec()])
            .bind()
            .await
        {
            Ok(ep) => {
                tracing::info!(node_id = %ep.id(), "iroh endpoint bound");
                Some(Arc::new(ep))
            }
            Err(e) => {
                tracing::warn!(error = %e, "iroh endpoint failed to bind; peer-to-peer sync unavailable");
                None
            }
        };
        tracing::info!(
            elapsed_ms = boot.elapsed().as_millis(),
            iroh = iroh_endpoint.is_some(),
            "repo peer endpoint ready"
        );

        let (events, _) = broadcast::channel(256);
        {
            let events = events.clone();
            tokio::spawn(async move {
                while let Ok(event) = ephemeral_rx.recv().await {
                    let sid = SedimentreeId::from(event.id);
                    if sid.as_bytes()[16..].iter().any(|byte| *byte != 0) {
                        continue;
                    }
                    let id = DocId::from_sedimentree_id(sid);
                    let _ = events.send(RepoEvent::Ephemeral(id, event.payload));
                }
            });
        }
        let repo = Arc::new(Repo {
            core,
            storage,
            signer,
            ephemeral,
            server_url,
            docs: Mutex::new(HashMap::new()),
            syncs: Mutex::new(HashMap::new()),
            pending_saves: Mutex::new(HashMap::new()),
            last_server_heads: Mutex::new(HashMap::new()),
            last_synced_local_heads: Mutex::new(HashMap::new()),
            next_save: AtomicU64::new(0),
            events,
            connected: AtomicBool::new(false),
            connect_started: AtomicBool::new(false),
            local_port,
            iroh_endpoint,
        });

        tracing::info!(
            elapsed_ms = boot.elapsed().as_millis(),
            port = ?local_port,
            "local subduction server listening on 127.0.0.1"
        );

        if let Some(listener) = listener {
            let node = repo.core.clone();
            let peer_id = PeerId::from(repo.signer.verifying_key());
            let audience = node.discovery_id().map(Audience::discover_id);
            let lp_signer = repo.signer.clone();
            let lp_peer_id = peer_id;
            let lp_discovery = audience;
            let lp_handler = LongPollHandler::new(
                lp_signer,
                std::sync::Arc::new(NonceCache::default()),
                lp_peer_id,
                lp_discovery,
                HANDSHAKE_MAX_DRIFT,
                FuturesTimerTimeout,
            );
            let relay_repo = repo.clone();
            tokio::spawn(async move {
                loop {
                    let Ok((tcp, _addr)) = listener.accept().await else {
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        continue;
                    };
                    let mut peek = [0u8; 4];
                    match tcp.peek(&mut peek).await {
                        Ok(n) if n >= 3 => {}
                        _ => continue,
                    }
                    if peek.starts_with(b"POST") || peek.starts_with(b"OPTI") {
                        tokio::spawn(accept_local_http_peer(
                            tcp,
                            node.clone(),
                            lp_handler.clone(),
                            relay_repo.ephemeral.clone(),
                        ));
                    } else {
                        tokio::spawn(accept_local_peer(
                            tcp,
                            node.clone(),
                            relay_repo.clone(),
                            peer_id,
                            audience,
                        ));
                    }
                }
            });
        }

        if let Some(iroh_ep) = repo.iroh_endpoint.clone() {
            let node = repo.core.clone();
            let signer = repo.signer.clone();
            let peer_id = PeerId::from(repo.signer.verifying_key());
            tokio::spawn(accept_iroh_peer(
                iroh_ep,
                node,
                signer,
                peer_id,
                repo.ephemeral.clone(),
            ));
        }

        {
            let repo = repo.clone();
            tokio::spawn(async move {
                while let Some(batch) = stored_rx.recv().await {
                    let id = DocId::from_sedimentree_id(batch.sedimentree_id);
                    let result = repo.apply_stored_batch(batch).await;
                    if let Err(ref e) = result {
                        tracing::warn!(doc = %id.to_url(), error = %e, "stored blobs failed to apply");
                        if let Err(e) = repo.apply_new_blobs(id).await {
                            tracing::warn!(doc = %id.to_url(), error = %e, "stored blob recovery failed");
                        }
                    }
                    if matches!(result, Ok(true)) {
                        repo.last_server_heads.lock().await.remove(&id);
                        repo.last_synced_local_heads.lock().await.remove(&id);
                    }
                }
            });
        }
        {
            let repo = repo.clone();
            tokio::spawn(async move {
                while let Some((sid, heads)) = heads_rx.recv().await {
                    repo.on_remote_heads(sid, heads).await;
                }
            });
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

    fn start_connect_loop_if_needed(self: &Arc<Self>) {
        if self.connect_started.swap(true, Ordering::Relaxed) {
            return;
        }
        tracing::info!("starting sync-server connection after local storage load");
        let repo = self.clone();
        tokio::spawn(async move { repo.connect_loop().await });
    }

    /// The discovery id a subduction websocket server registers itself under:
    /// whatever `new URL(url).host` gives automerge-repo, which keeps the port
    /// unless it's the scheme's default. Dropping it misses a local server,
    /// which listens as `127.0.0.1:<its port>`.
    fn service_name(uri: &tungstenite::http::Uri) -> String {
        let host = uri.host().unwrap_or("localhost");
        let default_port = match uri.scheme_str() {
            Some("wss" | "https") => Some(443),
            Some("ws" | "http") => Some(80),
            _ => None,
        };
        match uri.port_u16() {
            Some(port) if Some(port) != default_port => format!("{host}:{port}"),
            _ => host.to_string(),
        }
    }

    async fn connect_loop(self: Arc<Self>) {
        let uri: tungstenite::http::Uri = match self.server_url.parse() {
            Ok(u) => u,
            Err(e) => {
                tracing::error!(error = %e, url = %self.server_url, "invalid server url");
                return;
            }
        };
        let host = Self::service_name(&uri);
        let mut backoff = Duration::from_millis(500);
        loop {
            let audience = Audience::discover(host.as_bytes());
            match TokioWebSocketClient::new(uri.clone(), self.signer.clone(), audience).await {
                Ok((authenticated, listener_task, sender_task, keepalive_task)) => {
                    let peer_id = authenticated.peer_id();
                    tracing::info!(peer = %peer_id, "connected to sync server");
                    let connected_at = tokio::time::Instant::now();
                    let listener = tokio::spawn(listener_task.into_future());
                    let sender = tokio::spawn(sender_task.into_future());
                    let keepalive = tokio::spawn(async move {
                        keepalive_task.await;
                    });
                    if let Err(e) = self
                        .core
                        .add_connection(
                            authenticated.map(|c| MessageTransport::new(WsTransport::Dialed(c))),
                        )
                        .await
                    {
                        tracing::error!(error = %e, "failed to register connection");
                    } else {
                        self.connected
                            .store(true, std::sync::atomic::Ordering::Relaxed);
                        self.ephemeral.subscribe_peer(peer_id).await;
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
                    if connected_at.elapsed() >= Duration::from_secs(30) {
                        backoff = Duration::from_millis(500);
                    }
                }
                Err(e) => {
                    tracing::warn!(error = %e, "connection failed");
                }
            }
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(Duration::from_secs(30));
        }
    }

    pub async fn tracked_doc_ids(&self) -> Vec<DocId> {
        self.docs.lock().await.keys().copied().collect()
    }

    async fn resync_all(self: Arc<Self>) {
        for id in self.tracked_doc_ids().await {
            self.request_sync_forced(id).await;
        }
    }

    async fn on_remote_heads(self: &Arc<Self>, sid: SedimentreeId, heads: Vec<CommitId>) {
        if sid.as_bytes()[16..].iter().any(|byte| *byte != 0) {
            return;
        }
        let id = DocId::from_sedimentree_id(sid);
        if self.docs.lock().await.get(&id).is_none() {
            return;
        }
        let heads_set: BTreeSet<CommitId> = heads.iter().cloned().collect();
        if self.last_server_heads.lock().await.get(&id) == Some(&heads_set) {
            return;
        }
        let hashes: Vec<ChangeHash> = heads
            .iter()
            .map(|head| ChangeHash(*head.as_bytes()))
            .collect();
        let missing = {
            let Some(state) = self.docs.lock().await.get(&id).cloned() else {
                return;
            };
            let state = state.lock().await;
            !state.doc.get_missing_deps(&hashes).is_empty()
        };
        if !missing {
            self.last_server_heads.lock().await.insert(id, heads_set);
            return;
        }
        let _ = self.apply_new_blobs(id).await;
        let still_missing = {
            let Some(state) = self.docs.lock().await.get(&id).cloned() else {
                return;
            };
            let state = state.lock().await;
            !state.doc.get_missing_deps(&hashes).is_empty()
        };
        if still_missing {
            self.request_sync(id).await;
        } else {
            self.last_server_heads.lock().await.insert(id, heads_set);
        }
    }

    /// Run one sync round and apply whatever it landed in local storage.
    async fn sync_once(&self, id: DocId, timeout: CallTimeout) -> Result<SyncOutcome> {
        let peers = self
            .core
            .sync_with_all_peers(id.sedimentree_id(), true, timeout)
            .await
            .map_err(|e| anyhow!("sync failed: {e}"))?;
        let outcome = classify_sync(
            peers
                .values()
                .map(|(succeeded, stats, _)| (*succeeded, stats.total_received() > 0)),
        );
        if outcome.data_received() {
            self.apply_new_blobs(id).await?;
        }
        Ok(outcome)
    }

    async fn local_heads_for_sync(&self, id: DocId) -> Option<BTreeSet<CommitId>> {
        let state = self.docs.lock().await.get(&id).cloned()?;
        let heads = state.lock().await.doc.get_heads();
        Some(
            heads
                .into_iter()
                .map(|head| CommitId::new(head.0))
                .collect(),
        )
    }

    /// Ask for a sync round without waiting for it. Every background path goes
    /// through here so concurrent requests coalesce per doc.
    async fn request_sync(self: &Arc<Self>, id: DocId) {
        self.request_sync_inner(id, false).await;
    }

    async fn request_sync_forced(self: &Arc<Self>, id: DocId) {
        self.request_sync_inner(id, true).await;
    }

    async fn request_sync_inner(self: &Arc<Self>, id: DocId, force: bool) {
        if !self.is_connected() {
            return;
        }
        if !force {
            if let Some(heads) = self.local_heads_for_sync(id).await {
                if !heads.is_empty()
                    && self.last_synced_local_heads.lock().await.get(&id) == Some(&heads)
                {
                    return;
                }
            }
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
            let mut failures = 0u32;
            loop {
                let pre_round_heads = repo.local_heads_for_sync(id).await;
                let failed = match repo.sync_once(id, SYNC_TIMEOUT).await {
                    Ok(SyncOutcome::Failed { .. }) => {
                        let _ = repo.events.send(RepoEvent::SyncEvent(format!(
                            "{}: all peers failed",
                            short(id)
                        )));
                        true
                    }
                    Ok(SyncOutcome::NoPeers) => {
                        let _ = repo.events.send(RepoEvent::SyncEvent(format!(
                            "{}: no sync peers",
                            short(id)
                        )));
                        true
                    }
                    Ok(SyncOutcome::Succeeded { .. }) => {
                        if let Some(heads) = pre_round_heads {
                            repo.last_synced_local_heads.lock().await.insert(id, heads);
                        }
                        false
                    }
                    Err(e) => {
                        tracing::warn!(doc = %id.to_url(), error = %e, "sync failed");
                        let _ = repo
                            .events
                            .send(RepoEvent::SyncEvent(format!("{}: {e}", short(id))));
                        true
                    }
                };
                if failed {
                    failures += 1;
                    if failures < HEAL_MAX_ATTEMPTS && repo.is_connected() {
                        tokio::time::sleep(HEAL_DELAY).await;
                        continue;
                    }
                } else {
                    failures = 0;
                }
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

    /// Bring the in-memory doc up to date with local storage, applying stored
    /// blobs whose digests have not been applied yet. Returns true (and emits
    /// DocChanged) if the doc advanced.
    async fn stored_batch(&self, id: DocId) -> Result<StoredBatch> {
        let sid = id.sedimentree_id();
        let (commits, fragments) = tokio::try_join!(
            <ObservedStorage as Storage<Sendable>>::load_loose_commits(&self.storage, sid),
            <ObservedStorage as Storage<Sendable>>::load_fragments(&self.storage, sid),
        )
        .map_err(|e| anyhow!("loading stored blobs failed: {e}"))?;
        Ok(StoredBatch {
            sedimentree_id: sid,
            commits: commits
                .into_iter()
                .map(|verified| StoredRecord {
                    meta: verified.payload().clone(),
                    blob: verified.blob().clone(),
                })
                .collect(),
            fragments: fragments
                .into_iter()
                .map(|verified| StoredRecord {
                    meta: verified.payload().clone(),
                    blob: verified.blob().clone(),
                })
                .collect(),
        })
    }

    async fn apply_new_blobs(&self, id: DocId) -> Result<bool> {
        let batch = self.stored_batch(id).await?;
        self.apply_stored_batch(batch).await
    }

    fn emit_batch_events(&self, id: DocId, count: usize, advanced: bool, failed: bool) {
        if failed {
            let _ = self.events.send(RepoEvent::SyncEvent(format!(
                "{}: local storage incomplete; requesting repair",
                short(id)
            )));
        }
        if advanced {
            let _ = self.events.send(RepoEvent::SyncEvent(format!(
                "{}: doc advanced, {count} stored blobs",
                short(id)
            )));
            let _ = self.events.send(RepoEvent::DocChanged(id));
        }
    }

    async fn apply_stored_batch(&self, batch: StoredBatch) -> Result<bool> {
        if batch.sedimentree_id.as_bytes()[16..]
            .iter()
            .any(|byte| *byte != 0)
        {
            return Ok(false);
        }
        let id = DocId::from_sedimentree_id(batch.sedimentree_id);
        let count = batch.commits.len() + batch.fragments.len();
        let (advanced, failed) = {
            let Some(state) = self.docs.lock().await.get(&id).cloned() else {
                return Ok(false);
            };
            let mut state = state.lock().await;
            cpu_heavy(|| apply_batch_to_state(&mut state, batch, id))
        };
        self.emit_batch_events(id, count, advanced, failed);
        Ok(advanced)
    }

    /// Push any automerge fragments not yet in the sedimentree. Returns true if
    /// anything was stored.
    async fn save_doc(&self, id: DocId) -> Result<bool> {
        if let Some(pending) = self.pending_saves.lock().await.remove(&id) {
            pending.handle.abort();
        }
        self.save_doc_now(id).await
    }

    async fn save_doc_now(&self, id: DocId) -> Result<bool> {
        let sid = id.sedimentree_id();
        let shared = self.doc_state(id).await?;
        let ingested = {
            let state = shared.lock().await;
            cpu_heavy(|| {
                ingest(
                    &state.doc,
                    sid,
                    &state.stored_commits,
                    &state.stored_fragments,
                )
            })
        };
        let Some(ingested) = ingested else {
            tracing::warn!(doc = %id.to_url(), "fragment ingest failed; retrying on next save");
            return Ok(false);
        };
        if ingested.commits.is_empty() && ingested.fragments.is_empty() {
            return Ok(false);
        }

        let Ingested {
            commits,
            fragments,
            commit_heads,
            fragment_heads,
        } = ingested;
        self.core
            .store_built_batch(sid, commits, fragments)
            .await
            .map_err(|e| anyhow!("store_built_batch failed: {e}"))?;

        let mut state = shared.lock().await;
        state.stored_commits.extend(commit_heads);
        state.stored_fragments.extend(fragment_heads);

        Ok(true)
    }

    async fn schedule_save_doc(self: &Arc<Self>, id: DocId) {
        if let Some(pending) = self.pending_saves.lock().await.remove(&id) {
            pending.handle.abort();
        }
        let generation = self.next_save.fetch_add(1, Ordering::Relaxed);
        let repo = self.clone();
        let handle = tokio::spawn(async move {
            tokio::time::sleep(SAVE_DEBOUNCE).await;
            match repo.save_doc_now(id).await {
                Ok(true) => repo.request_sync(id).await,
                Ok(false) => {}
                Err(e) => tracing::warn!(doc = %id.to_url(), error = %e, "deferred save failed"),
            }
            let mut saves = repo.pending_saves.lock().await;
            if saves.get(&id).map(|pending| pending.generation) == Some(generation) {
                saves.remove(&id);
            }
        });
        self.pending_saves
            .lock()
            .await
            .insert(id, PendingSave { generation, handle });
    }

    /// Load a doc from local storage into memory (if not already tracked) and
    /// kick off a network sync + subscription in the background. Unsuccessful
    /// syncs are retried while a successful empty response is final.
    pub async fn ensure_doc(self: &Arc<Self>, id: DocId) -> Result<()> {
        let fresh = !self.docs.lock().await.contains_key(&id);
        self.open_local(id).await;
        if fresh {
            if self.doc_has_heads(id).await {
                match self.save_doc_now(id).await {
                    Ok(true) => {
                        let _ = self.events.send(RepoEvent::SyncEvent(format!(
                            "{}: repaired stored record layout",
                            short(id)
                        )));
                    }
                    Ok(false) => {}
                    Err(e) => {
                        tracing::warn!(doc = %id.to_url(), error = %e, "storage repair failed");
                    }
                }
            } else {
                let _ = self.events.send(RepoEvent::SyncEvent(format!(
                    "{}: storage empty on open",
                    short(id)
                )));
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
                match repo.sync_once(id, SYNC_TIMEOUT).await {
                    Ok(SyncOutcome::NoPeers | SyncOutcome::Failed { .. }) => {}
                    Ok(SyncOutcome::Succeeded { .. }) => return,
                    Err(e) => {
                        tracing::warn!(doc = %id.to_url(), error = %e, "sync failed");
                    }
                }
            }
        });
        Ok(())
    }

    async fn doc_has_heads(&self, id: DocId) -> bool {
        let Some(state) = self.docs.lock().await.get(&id).cloned() else {
            return false;
        };
        let has = !state.lock().await.doc.get_heads().is_empty();
        has
    }

    /// Block until a doc has content (or the timeout passes). Used when
    /// opening a doc we've never seen locally.
    pub async fn wait_for_doc(self: &Arc<Self>, id: DocId, timeout: Duration) -> bool {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            if self.doc_has_heads(id).await {
                return true;
            }
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(150)).await;
        }
    }

    pub async fn prefetch_doc(self: &Arc<Self>, id: DocId, timeout: Duration) {
        if self.docs.lock().await.contains_key(&id) {
            return;
        }
        let _ = self.ensure_doc(id).await;
        let _ = self.wait_for_doc(id, timeout).await;
    }

    pub async fn create_doc<F>(self: &Arc<Self>, init: F) -> Result<DocId>
    where
        F: FnOnce(&mut Automerge) -> Result<()>,
    {
        let id = DocId::random();
        let mut doc = Automerge::new();
        init(&mut doc)?;
        self.docs.lock().await.insert(id, DocState::shared(doc));
        self.ephemeral
            .subscribe(nonempty::NonEmpty::new(Topic::from(id.sedimentree_id())))
            .await;
        self.save_doc(id).await?;
        self.start_connect_loop_if_needed();
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
            let state = self.doc_state(id).await?;
            let mut state = state.lock().await;
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
            let state = self.doc_state(id).await?;
            let mut state = state.lock().await;
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
            let state = self.doc_state(id).await?;
            let mut state = state.lock().await;
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

    /// Read a doc, loading it from local storage first if it is not already
    /// tracked. A read must never report an untracked doc as empty: its content
    /// is on disk, and the sidebar walks nested folders through this path.
    pub async fn read_doc<F, T>(self: &Arc<Self>, id: DocId, f: F) -> Result<T>
    where
        F: FnOnce(&Automerge) -> Result<T>,
    {
        self.open_local(id).await;
        let state = self.doc_state(id).await?;
        let state = state.lock().await;
        f(&state.doc)
    }

    /// Read an already-tracked doc without waiting: fails fast when the doc
    /// lock is held instead of blocking the caller. For hot paths that are
    /// called synchronously from the UI thread and can just retry later.
    pub async fn try_read_doc<F, T>(&self, id: DocId, f: F) -> Result<T>
    where
        F: FnOnce(&Automerge) -> Result<T>,
    {
        let state = self.doc_state(id).await?;
        let state = state
            .try_lock()
            .map_err(|_| anyhow!("doc {} is busy", id.to_url()))?;
        f(&state.doc)
    }

    /// The lock for one doc, without holding the map lock while it is used.
    async fn doc_state(&self, id: DocId) -> Result<Arc<Mutex<DocState>>> {
        self.docs
            .lock()
            .await
            .get(&id)
            .cloned()
            .ok_or_else(|| anyhow!("unknown doc {}", id.to_url()))
    }

    /// Track a doc and populate it from local storage before allowing the
    /// sync-server connection loop to start. The fresh doc's lock is held
    /// across the initial load, so concurrent reads wait for the loaded doc
    /// instead of observing an empty one.
    async fn open_local(self: &Arc<Self>, id: DocId) {
        let mut guard = {
            let mut docs = self.docs.lock().await;
            if docs.contains_key(&id) {
                return;
            }
            let state = DocState::shared(Automerge::new());
            docs.insert(id, state.clone());
            state.try_lock_owned().expect("fresh doc lock")
        };
        self.ephemeral
            .subscribe(nonempty::NonEmpty::new(Topic::from(id.sedimentree_id())))
            .await;
        let (count, advanced, failed) = match self.stored_batch(id).await {
            Ok(batch) => {
                let count = batch.commits.len() + batch.fragments.len();
                let (advanced, failed) = cpu_heavy(|| apply_batch_to_state(&mut guard, batch, id));
                (count, advanced, failed)
            }
            Err(e) => {
                tracing::warn!(doc = %id.to_url(), error = %e, "local load failed");
                (0, false, false)
            }
        };
        drop(guard);
        self.emit_batch_events(id, count, advanced, failed);
        self.start_connect_loop_if_needed();
        self.request_sync(id).await;
    }

    /// Remove a doc from in-memory tracking so the next `ensure_doc` call
    /// reloads from storage and re-syncs. Useful when in-memory state is stuck.
    /// A pending debounced save is flushed first so its edits survive the drop.
    pub async fn drop_doc(&self, id: DocId) {
        if let Some(pending) = self.pending_saves.lock().await.remove(&id) {
            pending.handle.abort();
            if let Err(e) = self.save_doc_now(id).await {
                tracing::warn!(doc = %id.to_url(), error = %e, "flush before drop failed");
            }
        }
        self.docs.lock().await.remove(&id);
        self.syncs.lock().await.remove(&id);
        self.last_server_heads.lock().await.remove(&id);
        self.last_synced_local_heads.lock().await.remove(&id);
        self.ephemeral
            .unsubscribe(nonempty::NonEmpty::new(Topic::from(id.sedimentree_id())))
            .await;
    }

    /// Sign and fan out an opaque ephemeral payload on the doc's topic.
    /// Fire-and-forget: delivery is best-effort, nothing is persisted.
    pub async fn publish_ephemeral(&self, id: DocId, payload: Vec<u8>) {
        let ep = EphemeralPayload {
            id: Topic::from(id.sedimentree_id()),
            nonce: rand::random(),
            timestamp: TimestampSeconds::now(),
            payload,
        };
        let verified = Signed::seal::<Sendable, _>(&self.signer, ep).await;
        self.ephemeral
            .publish(EphemeralMessage::Ephemeral(Box::new(verified.into_signed())))
            .await;
    }

    /// One-shot: sync a doc and wait for the server to hold our heads.
    pub async fn flush(&self, id: DocId) -> Result<()> {
        self.save_doc(id).await?;
        if !self.wait_connected(Duration::from_secs(15)).await {
            return Err(anyhow!("not connected to sync server"));
        }
        match self.sync_once(id, SYNC_TIMEOUT).await? {
            SyncOutcome::Succeeded { .. } => Ok(()),
            SyncOutcome::NoPeers => Err(anyhow!("no sync peers connected")),
            SyncOutcome::Failed { .. } => Err(anyhow!("all sync peers failed")),
        }
    }

    /// Flush all pending saves and do a best-effort final sync before the app
    /// exits. Should be called from applicationWillTerminate / sceneDidDisconnect.
    pub async fn shutdown(self: &Arc<Self>) {
        let pending: Vec<(DocId, PendingSave)> = {
            let mut saves = self.pending_saves.lock().await;
            saves.drain().collect()
        };
        for (_, pending) in &pending {
            pending.handle.abort();
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

#[cfg(test)]
mod tests {
    use std::sync::atomic::Ordering as AtomicOrdering;

    use automerge::{transaction::Transactable, ActorId, ROOT};
    use tempfile::TempDir;
    use tokio::time::timeout;

    use super::*;

    #[test]
    fn service_name_matches_the_url_host() {
        let name = |url: &str| Repo::service_name(&url.parse().unwrap());
        assert_eq!(name("ws://127.0.0.1:43217"), "127.0.0.1:43217");
        assert_eq!(
            name("wss://subduction.sync.inkandswitch.com"),
            "subduction.sync.inkandswitch.com"
        );
        assert_eq!(name("wss://example.com:443"), "example.com");
        assert_eq!(name("ws://example.com:80/sync"), "example.com");
    }

    fn put(doc: &mut Automerge, key: &str, value: impl Into<automerge::ScalarValue>) {
        let mut tx = doc.transaction();
        tx.put(ROOT, key, value).unwrap();
        tx.commit();
    }

    async fn test_repo() -> (TempDir, Arc<Repo>) {
        let dir = tempfile::tempdir().unwrap();
        let repo = Repo::start(dir.path().to_path_buf(), "http://[".to_string())
            .await
            .unwrap();
        (dir, repo)
    }

    async fn wait_for_change(events: &mut broadcast::Receiver<RepoEvent>, id: DocId) {
        timeout(Duration::from_secs(2), async {
            loop {
                if matches!(events.recv().await.unwrap(), RepoEvent::DocChanged(changed) if changed == id)
                {
                    return;
                }
            }
        })
        .await
        .unwrap();
    }

    #[test]
    fn sync_results_distinguish_no_peers_failure_and_success() {
        assert_eq!(classify_sync([]), SyncOutcome::NoPeers);
        assert_eq!(
            classify_sync([(false, false), (false, true)]),
            SyncOutcome::Failed {
                data_received: true
            }
        );
        assert_eq!(
            classify_sync([(false, true), (true, false)]),
            SyncOutcome::Succeeded {
                data_received: true
            }
        );
        assert_eq!(
            classify_sync([(true, false)]),
            SyncOutcome::Succeeded {
                data_received: false
            }
        );
    }

    #[test]
    fn stored_fragments_load_in_causal_order() {
        let mut source = Automerge::new().with_actor(ActorId::from([7; 16].as_slice()));
        for index in 0..1_000 {
            put(
                &mut source,
                &format!("value-{index}"),
                format!("value-{index:04}-{:08x}", index * 7919),
            );
        }
        let ingested = ingest(
            &source,
            DocId([7; 16]).sedimentree_id(),
            &HashSet::new(),
            &HashSet::new(),
        )
        .unwrap();
        let mut commits: Vec<_> = ingested
            .commits
            .into_iter()
            .map(|(meta, blob)| StoredRecord { meta, blob })
            .collect();
        let mut fragments: Vec<_> = ingested
            .fragments
            .into_iter()
            .map(|(meta, blob)| StoredRecord { meta, blob })
            .collect();
        assert!(commits.len() + fragments.len() > 1);
        commits.reverse();
        fragments.reverse();

        let mut loaded = Automerge::new();
        let applied = load_blob_batch(&mut loaded, &commits, &fragments).unwrap();

        assert_eq!(applied.len(), commits.len() + fragments.len());
        assert_eq!(loaded.get_heads(), source.get_heads());
    }

    #[tokio::test]
    async fn stored_fragments_survive_local_reopen() {
        let (_dir, repo) = test_repo().await;
        let id = DocId([8; 16]);
        let mut source = Automerge::new().with_actor(ActorId::from([8; 16].as_slice()));
        for index in 0..1_000 {
            put(&mut source, &format!("value-{index}"), index as i64);
        }
        let ingested = ingest(
            &source,
            id.sedimentree_id(),
            &HashSet::new(),
            &HashSet::new(),
        )
        .unwrap();
        assert!(!ingested.fragments.is_empty());
        repo.core
            .store_built_batch(id.sedimentree_id(), ingested.commits, ingested.fragments)
            .await
            .unwrap();

        repo.ensure_doc(id).await.unwrap();
        assert_eq!(
            repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap(),
            source.get_heads()
        );

        repo.drop_doc(id).await;
        repo.ensure_doc(id).await.unwrap();
        assert_eq!(
            repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap(),
            source.get_heads()
        );
    }

    #[test]
    fn ingest_batches_level_zero_runs_into_fragments() {
        let id = DocId([12; 16]);
        let sid = id.sedimentree_id();
        let mut source = Automerge::new().with_actor(ActorId::from([12; 16].as_slice()));

        while get_level_zero_count(&source) < LOOSE_FRAGMENT_BATCH_SIZE {
            let index = source.length(ROOT);
            put(&mut source, &format!("value-{index}"), index as i64);
        }

        let ingested = ingest(&source, sid, &HashSet::new(), &HashSet::new()).unwrap();
        assert!(
            !ingested.fragments.is_empty(),
            "level-0 changes should be batched into fragment records"
        );
        assert!(
            ingested.commits.len() < LOOSE_FRAGMENT_BATCH_SIZE,
            "only the below-threshold tail should remain loose"
        );

        let commits: Vec<_> = ingested
            .commits
            .into_iter()
            .map(|(meta, blob)| StoredRecord { meta, blob })
            .collect();
        let fragments: Vec<_> = ingested
            .fragments
            .into_iter()
            .map(|(meta, blob)| StoredRecord { meta, blob })
            .collect();
        let mut loaded = Automerge::new();
        load_blob_batch(&mut loaded, &commits, &fragments).unwrap();

        assert_eq!(loaded.get_heads(), source.get_heads());
    }

    fn get_level_zero_count(doc: &Automerge) -> usize {
        doc.fragments(0..=0).len()
    }

    #[tokio::test]
    async fn persisted_batches_advance_tracked_docs_and_durable_ids() {
        let (_dir, repo) = test_repo().await;
        let id = DocId([3; 16]);
        repo.docs
            .lock()
            .await
            .insert(id, DocState::shared(Automerge::new()));
        let mut events = repo.subscribe();

        let mut source = Automerge::new();
        put(&mut source, "value", "stored");
        let ingested = ingest(
            &source,
            id.sedimentree_id(),
            &HashSet::new(),
            &HashSet::new(),
        )
        .unwrap();
        let commit_heads = ingested.commit_heads.clone();
        let fragment_heads = ingested.fragment_heads.clone();

        repo.core
            .store_built_batch(id.sedimentree_id(), ingested.commits, ingested.fragments)
            .await
            .unwrap();
        wait_for_change(&mut events, id).await;

        let sid = id.sedimentree_id();
        let (commit_ids, fragment_ids) = tokio::try_join!(
            <ObservedStorage as Storage<Sendable>>::list_commit_ids(&repo.storage, sid),
            <ObservedStorage as Storage<Sendable>>::list_fragment_ids(&repo.storage, sid),
        )
        .unwrap();
        for head in &commit_heads {
            assert!(commit_ids.contains(&CommitId::new(head.0)));
        }
        for head in &fragment_heads {
            assert!(fragment_ids.contains(&CommitId::new(head.0)));
        }

        let state = repo.docs.lock().await.get(&id).cloned().unwrap();
        let state = state.lock().await;
        assert_eq!(state.doc.get_heads(), source.get_heads());
        assert_eq!(state.stored_commits.len(), commit_heads.len());
        assert_eq!(state.stored_fragments.len(), fragment_heads.len());
        let repeated = ingest(
            &state.doc,
            sid,
            &state.stored_commits,
            &state.stored_fragments,
        )
        .unwrap();
        assert!(repeated.commits.is_empty());
        assert!(repeated.fragments.is_empty());
    }

    #[tokio::test]
    async fn opening_legacy_storage_adds_the_canonical_record_kind() {
        let (_dir, repo) = test_repo().await;
        let id = DocId([4; 16]);
        let sid = id.sedimentree_id();
        let mut source = Automerge::new().with_actor(ActorId::from([11; 16].as_slice()));
        put(&mut source, "value", "legacy");
        let mut ingested = ingest(&source, sid, &HashSet::new(), &HashSet::new()).unwrap();
        assert_eq!(ingested.commits.len(), 1);
        assert!(ingested.fragments.is_empty());
        let (commit, blob) = ingested.commits.pop().unwrap();
        let head = commit.head();
        let legacy = SedimentreeFragment::new(
            sid,
            head,
            commit.parents().clone(),
            &[],
            BlobMeta::new(&blob),
        );

        repo.core
            .store_built_batch(sid, Vec::new(), vec![(legacy, blob)])
            .await
            .unwrap();
        repo.ensure_doc(id).await.unwrap();

        let (commit_ids, fragment_ids) = tokio::try_join!(
            <ObservedStorage as Storage<Sendable>>::list_commit_ids(&repo.storage, sid),
            <ObservedStorage as Storage<Sendable>>::list_fragment_ids(&repo.storage, sid),
        )
        .unwrap();
        assert!(commit_ids.contains(&head));
        assert!(fragment_ids.contains(&head));
        assert_eq!(
            repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap(),
            source.get_heads()
        );
    }

    #[tokio::test]
    async fn incomplete_local_storage_continues_to_server_repair() {
        let (_dir, repo) = test_repo().await;
        let id = DocId([5; 16]);
        let sid = id.sedimentree_id();
        let blob = Blob::new(vec![1, 2, 3]);
        let commit = LooseCommit::new(
            sid,
            CommitId::new([9; 32]),
            BTreeSet::new(),
            BlobMeta::new(&blob),
        );
        repo.core
            .store_built_batch(sid, vec![(commit, blob)], Vec::new())
            .await
            .unwrap();
        let mut events = repo.subscribe();

        repo.ensure_doc(id).await.unwrap();

        timeout(Duration::from_secs(2), async {
            loop {
                if matches!(events.recv().await.unwrap(), RepoEvent::SyncEvent(message) if message.contains("requesting repair"))
                {
                    return;
                }
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn deferred_change_survives_drop_doc() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "first", "saved");
                Ok(())
            })
            .await
            .unwrap();
        let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        repo.change_doc_at_deferred_save(id, heads, |doc| {
            put(doc, "second", "deferred");
            Ok(())
        })
        .await
        .unwrap();
        let expected = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();

        repo.drop_doc(id).await;
        repo.ensure_doc(id).await.unwrap();
        let loaded = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        assert_eq!(loaded, expected);
    }

    #[tokio::test]
    async fn flush_persists_a_deferred_change_before_syncing() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "first", "saved");
                Ok(())
            })
            .await
            .unwrap();
        let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        repo.change_doc_at_deferred_save(id, heads, |doc| {
            put(doc, "second", "deferred");
            Ok(())
        })
        .await
        .unwrap();
        let expected = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();

        repo.connected.store(true, AtomicOrdering::Relaxed);
        assert!(repo.flush(id).await.is_err());
        repo.connected.store(false, AtomicOrdering::Relaxed);

        repo.drop_doc(id).await;
        repo.ensure_doc(id).await.unwrap();
        let loaded = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        assert_eq!(loaded, expected);
    }
}
