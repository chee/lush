use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    future::IntoFuture,
    io::Write,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

use anyhow::{anyhow, Context, Result};
use async_tungstenite::{tokio::TokioAdapter, tungstenite::protocol::WebSocketConfig};
use automerge::{Automerge, ChangeHash, ReadDoc};
use future_form::Sendable;
use futures::{future::BoxFuture, FutureExt, StreamExt};
use sedimentree_core::{
    blob::{Blob, BlobMeta},
    collections::Map,
    crypto::digest::Digest,
    depth::CountLeadingZeroBytes,
    fragment::Fragment as SedimentreeFragment,
    id::SedimentreeId,
    loose_commit::{id::CommitId, LooseCommit},
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
/// How long an edit waits to be folded into the sedimentree. Not a
/// durability window: `change_doc_at_deferred_ingest` has already logged the
/// edit by the time this starts, and the log is replayed on load.
const SAVE_DEBOUNCE: Duration = Duration::from_millis(90);
const HEAL_DELAY: Duration = Duration::from_secs(5);
const HEAL_MAX_ATTEMPTS: u32 = 12;
const LOCAL_SERVER_PORT: u16 = 43219;
const HANDSHAKE_MAX_DRIFT: Duration = Duration::from_secs(600);
/// How many absorbed commits to delete at once. Deleting one at a time makes a
/// pass over a doc with thousands of them crawl; unbounded floods the disk.
const RECLAIM_DELETE_CONCURRENCY: usize = 16;
/// How long a freshly accepted loopback socket has to reveal what protocol it
/// speaks. A silent connection used to wedge the whole accept loop.
const LOCAL_PEEK_TIMEOUT: Duration = Duration::from_secs(5);
/// Depth of the queues carrying saved blobs and observed remote heads. Bounded
/// so a burst of writes back-pressures the writer instead of piling cloned
/// blobs up in memory.
const OBSERVER_QUEUE: usize = 64;
const EVICT_SWEEP_INTERVAL: Duration = Duration::from_secs(60);
const EVICT_IDLE: Duration = Duration::from_secs(300);
/// Ceiling on resident docs. A count is a poor stand-in for a size — one
/// long-edited note can outweigh forty short ones — so it is a backstop, and
/// the only trigger left on platforms where `headroom` says nothing.
const MAX_RESIDENT_DOCS: usize = 48;
/// Headroom below which the sweep stops waiting for docs to go idle.
const LOW_HEADROOM: u64 = 96 * 1024 * 1024;

/// Bytes this process may still allocate before the OS kills it, when the OS
/// will say. iOS gives an app a footprint limit and jetsams it on contact, with
/// no failed allocation to catch first, so this is the only number that says
/// how close the drop is. Zero means no limit is being enforced — every macOS
/// process, and anything that isn't an app — and reads as `None`.
#[cfg(target_vendor = "apple")]
fn headroom() -> Option<u64> {
    extern "C" {
        fn os_proc_available_memory() -> usize;
    }
    let free = unsafe { os_proc_available_memory() } as u64;
    (free > 0).then_some(free)
}

#[cfg(not(target_vendor = "apple"))]
fn headroom() -> Option<u64> {
    None
}

/// Whether the sweep takes the next-oldest doc. Past the idle threshold it
/// always does; short of it, only to get back under the resident ceiling or
/// out of the low-headroom margin.
fn sweep_takes(age: Duration, idle: Duration, resident: usize, headroom: Option<u64>) -> bool {
    age >= idle || resident > MAX_RESIDENT_DOCS || headroom.is_some_and(|free| free < LOW_HEADROOM)
}

/// Requests reaching the loopback sync server must come from the app's own
/// webview, which loads under the custom `lushweb://` scheme. Native peers send
/// no Origin header; a browser page on another origin always does, so we accept
/// a missing Origin but reject any that isn't ours.
fn origin_allowed(origin: Option<&str>) -> bool {
    match origin {
        None => true,
        Some(o) => o.starts_with("lushweb://"),
    }
}

/// A local-peer WebSocket transport that notices incoming BatchSyncRequests for
/// docs this device isn't tracking and starts fetching them from the remote
/// server. The message goes straight on to the SyncHandler: the prefetch runs
/// alongside it, so a doc the server has never heard of can't hold up the
/// socket's whole receive path. What lands arrives as an ordinary sync update.
///
/// The repo reference is held outside this type (in a spawned task) to avoid
/// a recursive type-parameter cycle that would make the Sync bound overflow.
#[derive(Debug, Clone)]
pub struct PrefetchTransport {
    inner: WebSocket<TokioAdapter<TcpStream>, Sendable>,
    prefetch_tx: mpsc::UnboundedSender<SedimentreeId>,
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
    Dialed(Box<TokioWebSocketClient<MemorySigner>>),
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
                let fut = Transport::<Sendable>::send_bytes(ws.as_ref(), bytes);
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
            Self::Dialed(ws) => Transport::<Sendable>::recv_bytes(ws.as_ref())
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
                            let _ = prefetch_tx.send(req.id);
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
            Self::Dialed(ws) => Transport::<Sendable>::disconnect(ws.as_ref())
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

/// A dialer only knows our iroh node id, not our subduction peer id, so it
/// addresses the handshake to a discovery audience hashed from that node id.
fn iroh_audience(node_id: &iroh::EndpointId) -> Audience {
    Audience::discover(node_id.to_string().as_bytes())
}

async fn accept_iroh_peer(endpoint: Arc<iroh::Endpoint>, repo: Arc<Repo>) {
    let signer = repo.signer.clone();
    let peer_id = PeerId::from(repo.signer.verifying_key());
    let audience = Some(iroh_audience(&endpoint.id()));
    let nonce_cache = NonceCache::default();
    loop {
        match subduction_iroh::server::accept_one(
            &endpoint,
            &signer,
            &nonce_cache,
            peer_id,
            audience,
            HANDSHAKE_MAX_DRIFT,
        )
        .await
        {
            Ok(result) => {
                tokio::spawn(result.listener_task);
                tokio::spawn(result.sender_task);
                let mut node_id = None;
                let mapped = result.authenticated.map(|c| {
                    node_id = Some(c.quic_connection().remote_id().to_string());
                    MessageTransport::new(WsTransport::Iroh(c))
                });
                let peer = mapped.peer_id();
                if let Err(e) = repo.core.add_connection(mapped).await {
                    tracing::warn!(error = %e, "iroh: add_connection failed");
                    continue;
                }
                repo.ephemeral.subscribe_peer(peer).await;
                if let Some(node_id) = node_id {
                    repo.note_iroh_peer_seen(node_id, peer);
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
            let allowed_origin = req
                .headers()
                .get(hyper::header::ORIGIN)
                .and_then(|v| v.to_str().ok())
                .filter(|o| origin_allowed(Some(o)))
                .and_then(|o| HeaderValue::from_str(o).ok());
            if req.method() == hyper::Method::OPTIONS {
                let mut resp = hyper::Response::new(Full::new(Bytes::new()));
                *resp.status_mut() = hyper::StatusCode::NO_CONTENT;
                if let Some(origin) = allowed_origin.clone() {
                    resp.headers_mut()
                        .insert(ACCESS_CONTROL_ALLOW_ORIGIN, origin);
                    resp.headers_mut()
                        .insert(hyper::header::VARY, HeaderValue::from_static("Origin"));
                }
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
            if let Some(origin) = allowed_origin {
                parts.headers.insert(ACCESS_CONTROL_ALLOW_ORIGIN, origin);
                parts
                    .headers
                    .insert(hyper::header::VARY, HeaderValue::from_static("Origin"));
            }
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
        |req: &tungstenite::handshake::server::Request,
         resp: tungstenite::handshake::server::Response| {
            let origin = req
                .headers()
                .get(tungstenite::http::header::ORIGIN)
                .and_then(|v| v.to_str().ok());
            if origin_allowed(origin) {
                Ok(resp)
            } else {
                Err(tungstenite::http::Response::builder()
                    .status(tungstenite::http::StatusCode::FORBIDDEN)
                    .body(None)
                    .unwrap())
            }
        },
        Some(ws_config),
    )
    .await
    {
        Ok(ws) => ws,
        Err(_) => return,
    };

    let (prefetch_tx, mut prefetch_rx) = mpsc::unbounded_channel::<SedimentreeId>();

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
        while let Some(sid) = prefetch_rx.recv().await {
            if sid.as_bytes()[16..].iter().any(|byte| *byte != 0) {
                continue;
            }
            let repo = repo.clone();
            tokio::spawn(async move {
                repo.prefetch_doc(DocId::from_sedimentree_id(sid), Duration::from_secs(30))
                    .await;
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
    id.to_url()[10..22].to_string()
}

#[derive(Debug, Clone)]
pub enum RepoEvent {
    DocChanged(DocId),
    Connected,
    Disconnected,
    SyncEvent(String),
    Ephemeral(DocId, Vec<u8>),
    PeersChanged,
    /// Local storage has been enumerated: what this device already holds is
    /// known. Dialing the server before this asks for things we have.
    StorageLoaded,
    NotesPrefetched,
}

#[derive(Debug, Clone)]
struct HeadsObserver {
    tx: mpsc::Sender<(SedimentreeId, Vec<CommitId>)>,
}

/// The observer hook is synchronous, so a full queue can't be awaited inline.
/// Handing the item to a task keeps back-pressure without ever dropping a
/// report — a dropped one would leave a doc waiting for the next server nudge.
impl RemoteHeadsObserver for HeadsObserver {
    fn on_remote_heads(&self, id: SedimentreeId, _peer: PeerId, heads: RemoteHeads) {
        if let Err(mpsc::error::TrySendError::Full(item)) = self.tx.try_send((id, heads.heads)) {
            let tx = self.tx.clone();
            tokio::spawn(async move {
                let _ = tx.send(item).await;
            });
        }
    }
}

struct DocState {
    doc: Automerge,
    stored_commits: HashSet<ChangeHash>,
    stored_fragments: HashSet<ChangeHash>,
    applied: HashSet<Digest<Blob>>,
    failed: HashSet<Digest<Blob>>,
    /// Heads the outbox file already holds, when it holds anything. Lets a
    /// stage append the changes since instead of recompacting the whole doc.
    staged_heads: Option<Vec<ChangeHash>>,
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
            failed: HashSet::new(),
            staged_heads: None,
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
    outbox_dir: PathBuf,
    /// The outer lock only guards the map. Each doc carries its own lock, so
    /// decoding blobs into one doc or building fragments for it does not stall
    /// reads of every other doc — which is what the UI does on every keystroke.
    docs: Mutex<HashMap<DocId, Arc<Mutex<DocState>>>>,
    last_touched: std::sync::Mutex<HashMap<DocId, Instant>>,
    pins: std::sync::Mutex<HashMap<DocId, u32>>,
    syncs: Mutex<HashMap<DocId, SyncSlot>>,
    pending_saves: Mutex<HashMap<DocId, PendingSave>>,
    last_server_heads: Mutex<HashMap<DocId, BTreeSet<CommitId>>>,
    last_synced_local_heads: Mutex<HashMap<DocId, BTreeSet<CommitId>>>,
    deferred_applies: Mutex<HashSet<DocId>>,
    deferred_sends: Mutex<HashSet<DocId>>,
    next_save: AtomicU64,
    events: broadcast::Sender<RepoEvent>,
    connected: AtomicBool,
    connect_started: AtomicBool,
    apply_incoming: AtomicBool,
    send_changes: AtomicBool,
    local_port: Option<u16>,
    iroh_key_path: PathBuf,
    iroh_endpoint: std::sync::Mutex<Option<Arc<iroh::Endpoint>>>,
    /// Serializes enable/disable so a bind and a close can't interleave.
    iroh_lifecycle: Mutex<()>,
    /// One lock per doc around its outbox file. Appending to the log and
    /// truncating it after an ingest both mutate the same file plus the same
    /// `staged_heads`, and a keystroke can land while a debounced save is
    /// still running — interleaving them would strand changes in neither
    /// place. Not the doc lock: the append fsyncs, and reads shouldn't wait.
    outbox_locks: std::sync::Mutex<HashMap<DocId, Arc<Mutex<()>>>>,
    /// Held for the duration of an idle sweep, so the repeating memory-pressure
    /// signal runs one sweep rather than one per warning.
    sweep_lock: Mutex<()>,
    peers_path: PathBuf,
    peers: std::sync::Mutex<Peers>,
}

/// Peers we sync with, keyed by iroh node id, valued by their subduction peer
/// id where we know it. `added` are dialed on every launch; `seen` are peers
/// who dialed us — offered in the UI as suggestions, not dialed back.
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
pub struct Peers {
    #[serde(default)]
    added: BTreeMap<String, Option<String>>,
    #[serde(default)]
    seen: BTreeMap<String, Option<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IrohPeerEntry {
    pub node_id: String,
    pub peer_id: Option<String>,
    pub added: bool,
}

/// `<iroh node id>:<subduction peer id>`, both hex. A bare node id still works
/// — then the dialer has to fall back to a discovery audience.
fn parse_friend_code(code: &str) -> Result<(iroh::EndpointId, Option<PeerId>)> {
    let code = code.trim();
    let (node, peer) = code.split_once(':').unwrap_or((code, ""));
    let node_id = node
        .trim()
        .parse()
        .map_err(|e| anyhow!("invalid iroh node id: {e}"))?;
    if peer.trim().is_empty() {
        return Ok((node_id, None));
    }
    let bytes: [u8; 32] = hex::decode(peer.trim())
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or_else(|| anyhow!("invalid peer id: expected 64 hex characters"))?;
    Ok((node_id, Some(PeerId::new(bytes))))
}

fn load_peers(path: &Path) -> Peers {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
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
    skipped: bool,
}

/// Decompose the doc's automerge fragments into sedimentree records, skipping
/// anything already stored. A level-0 fragment becomes a loose commit; a
/// level-1-or-higher fragment becomes a fragment record.
///
/// Automerge core owns the compaction policy. Once it forms a fragment, the
/// commits absorbed into it stop appearing at level 0 and the fragment appears
/// at level >= 1, so the stored shape follows automerge's own view of the doc
/// without this function deciding anything.
/// `bench_natural_fragment_formation` records the rate: 8000 changes of
/// ordinary editing leave 27 fragments and a tail of 106 loose commits.
///
/// This mirrors `@automerge/automerge-repo`'s subduction source, which reads
/// fragment metadata, filters it against the hashes it has already stored, and
/// bundles only what survives. Bundling is the expensive half and is O(n) per
/// item, so it has to stay behind the filter — enumerating metadata is
/// comparatively cheap (1.6ms for a 10k-change note; see
/// `bench_ingest_breakdown`).
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
        let mut out = Ingested {
            commits: Vec::new(),
            fragments: Vec::new(),
            commit_heads: Vec::new(),
            fragment_heads: Vec::new(),
            skipped: false,
        };
        for f in doc.fragments(0..) {
            let head = f.head;
            let level = f.level;
            let already = if level == 0 {
                stored_commits.contains(&head)
            } else {
                stored_fragments.contains(&head)
            };
            if already {
                continue;
            }
            let boundary: BTreeSet<CommitId> =
                f.boundary.iter().map(|h| CommitId::new(h.0)).collect();
            let checkpoints: Vec<CommitId> =
                f.checkpoints.iter().map(|h| CommitId::new(h.0)).collect();
            let Some(bytes) = doc.bundle_fragments([f]).into_iter().next() else {
                tracing::warn!(
                    ?head,
                    level,
                    "fragment failed to bundle; retrying on next save"
                );
                out.skipped = true;
                continue;
            };
            let blob = Blob::new(bytes);
            let meta = BlobMeta::new(&blob);
            let id = CommitId::new(head.0);
            if level == 0 {
                out.commits
                    .push((LooseCommit::new(sid, id, boundary, meta), blob));
                out.commit_heads.push(head);
            } else {
                out.fragments.push((
                    SedimentreeFragment::new(sid, id, boundary, &checkpoints, meta),
                    blob,
                ));
                out.fragment_heads.push(head);
            }
        }
        out
    }))
    .ok()
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

fn catching<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|cause| {
        let msg = cause
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| cause.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "unknown panic".into());
        Err(anyhow!(
            "internal error (automerge panic: {msg}); the change was not saved"
        ))
    })
}

fn apply_batch_to_state(state: &mut DocState, batch: StoredBatch, id: DocId) -> (bool, bool) {
    // automerge logs its own parse warnings with no idea which doc they are;
    // the span puts the url on them.
    let _span = tracing::info_span!("doc", doc = %id.to_url()).entered();
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
            let d = BlobMeta::new(&record.blob).digest();
            !state.applied.contains(&d) && !state.failed.contains(&d)
        })
        .collect();
    let fragments: Vec<_> = batch
        .fragments
        .into_iter()
        .filter(|record| {
            let d = BlobMeta::new(&record.blob).digest();
            !state.applied.contains(&d) && !state.failed.contains(&d)
        })
        .collect();
    if commits.is_empty() && fragments.is_empty() {
        return (false, false);
    }
    let before = state.doc.get_heads();
    let (bytes, parts) = concat_blob_batch(commits, fragments);
    match state.doc.load_incremental(&bytes) {
        Ok(_) => {
            state
                .applied
                .extend(parts.into_iter().map(|(digest, _)| digest));
            (state.doc.get_heads() != before, false)
        }
        Err(e) => {
            tracing::warn!(doc = %id.to_url(), error = %e, "stored blob batch could not be ordered; loading in storage order");
            let mut any_failed = false;
            for (digest, range) in parts {
                if state.applied.contains(&digest) {
                    continue;
                }
                match catching(|| Ok(state.doc.load_incremental(&bytes[range])?)) {
                    Ok(_) => {
                        state.applied.insert(digest);
                    }
                    Err(e) => {
                        tracing::warn!(doc = %id.to_url(), %digest, error = %e, "stored blob failed to load");
                        state.failed.insert(digest);
                        any_failed = true;
                    }
                }
            }
            (state.doc.get_heads() != before, any_failed)
        }
    }
}

/// Lay a batch's stored blobs end to end for one `load_incremental`, which
/// takes any concatenation of `save_incremental` output — loose commits and
/// fragment bundles, in any order — and resolves the dependencies itself.
///
/// Consumes the records as it copies, so the concatenation replaces the blobs
/// rather than doubling them, and returns each blob's range in the buffer so a
/// batch that won't load can be retried one blob at a time without a second
/// copy.
fn concat_blob_batch(
    commits: Vec<StoredRecord<LooseCommit>>,
    fragments: Vec<StoredRecord<SedimentreeFragment>>,
) -> (Vec<u8>, Vec<(Digest<Blob>, std::ops::Range<usize>)>) {
    // One blob is already its own concatenation — the shape a live sync delta
    // and a whole asset doc arrive in. automerge-repo skips the same copy
    // (`blobs.length === 1 ? blobs[0] : mergeArrays(blobs)`, source.ts).
    if commits.len() + fragments.len() == 1 {
        let blob = match commits.into_iter().next() {
            Some(record) => record.blob,
            None => fragments.into_iter().next().expect("one record").blob,
        };
        let digest = BlobMeta::new(&blob).digest();
        let bytes = Vec::from(blob);
        let len = bytes.len();
        return (bytes, vec![(digest, 0..len)]);
    }
    // Sized up front: growing by doubling would leave both buffers live at
    // once, on the path a device short of memory takes to open a note.
    let total: usize = commits
        .iter()
        .map(|record| record.blob.as_slice().len())
        .chain(fragments.iter().map(|record| record.blob.as_slice().len()))
        .sum();
    let mut bytes = Vec::with_capacity(total);
    let mut parts = Vec::new();
    let mut seen = HashSet::new();
    for blob in commits
        .into_iter()
        .map(|record| record.blob)
        .chain(fragments.into_iter().map(|record| record.blob))
    {
        let digest = BlobMeta::new(&blob).digest();
        if !seen.insert(digest) {
            continue;
        }
        let start = bytes.len();
        bytes.extend_from_slice(blob.as_slice());
        parts.push((digest, start..bytes.len()));
    }
    (bytes, parts)
}

/// Load a whole batch into `doc`, for callers with no use for the per-blob
/// retry: a batch that won't order is an error to them, not something to
/// pick apart.
fn load_blob_batch(
    doc: &mut Automerge,
    commits: Vec<StoredRecord<LooseCommit>>,
    fragments: Vec<StoredRecord<SedimentreeFragment>>,
) -> Result<Vec<Digest<Blob>>> {
    let (bytes, parts) = concat_blob_batch(commits, fragments);
    if !bytes.is_empty() {
        doc.load_incremental(&bytes)?;
    }
    Ok(parts.into_iter().map(|(digest, _)| digest).collect())
}

/// Fsync the directory holding `path`, so a create or a delete of the entry
/// itself survives, not just the file contents.
fn sync_dir(path: &Path) {
    if let Some(parent) = path.parent() {
        if let Ok(dir) = std::fs::File::open(parent) {
            let _ = dir.sync_all();
        }
    }
}

/// Replay an outbox log onto a doc already carrying everything the
/// sedimentree holds. The log is a compacted document followed by appended
/// change chunks, and `load_incremental` takes both — importantly including
/// a log that starts mid-history, which is what one looks like after
/// `truncate_outbox` restarts it from the last ingested heads.
fn merge_outbox_into(doc: &mut Automerge, bytes: &[u8]) -> Result<()> {
    match doc.load_incremental(bytes) {
        Ok(_) => Ok(()),
        // Logs written before the format carried deltas across an ingest are
        // whole documents; those still merge the old way.
        Err(e) => {
            let mut staged = Automerge::load(bytes).map_err(|_| anyhow!("{e}"))?;
            doc.merge(&mut staged)?;
            Ok(())
        }
    }
}

impl Repo {
    fn outbox_path(&self, id: DocId) -> PathBuf {
        self.outbox_dir
            .join(format!("{}.automerge", hex::encode(id.0)))
    }

    fn outbox_lock(&self, id: DocId) -> Arc<Mutex<()>> {
        self.outbox_locks
            .lock()
            .unwrap()
            .entry(id)
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    /// Mirror the in-memory doc into the outbox file, and don't come back
    /// until it is on the disk.
    ///
    /// This is the commit point for an edit. Building sedimentree fragments
    /// costs tens of milliseconds and climbs with the note's history, so the
    /// editor's keystroke path can't wait for it — but it can wait for this,
    /// which appends only the changes since the last stage. `open_local`
    /// replays the log over the sedimentree, so an edit that got this far is
    /// recoverable even if the process is killed a moment later.
    ///
    /// The first stage after a truncation writes a compacted document; every
    /// stage after it appends.
    async fn stage_doc(&self, id: DocId) -> Result<()> {
        let outbox = self.outbox_lock(id);
        let _outbox = outbox.lock().await;
        let state = self.doc_state(id).await?;
        let (bytes, heads, append) = {
            let guard = state.lock().await;
            let heads = guard.doc.get_heads();
            match guard.staged_heads.clone() {
                Some(staged) if staged == heads => return Ok(()),
                Some(staged) => (cpu_heavy(|| guard.doc.save_after(&staged)), heads, true),
                None => (cpu_heavy(|| guard.doc.save()), heads, false),
            }
        };
        let path = self.outbox_path(id);
        cpu_heavy(|| -> Result<()> {
            if append {
                let mut file = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
                    .context("opening staged doc")?;
                file.write_all(&bytes).context("appending staged doc")?;
                // A kill leaves written-but-unflushed bytes intact, but a
                // panic or a flat battery does not, and this is the only
                // copy of the edit until the next ingest.
                file.sync_all().context("flushing staged doc")?;
            } else {
                let pending = path.with_extension("pending");
                std::fs::write(&pending, &bytes).context("writing staged doc")?;
                let file = std::fs::File::open(&pending).context("reopening staged doc")?;
                file.sync_all().context("flushing staged doc")?;
                std::fs::rename(&pending, &path).context("committing staged doc")?;
                sync_dir(&path);
            }
            Ok(())
        })?;
        state.lock().await.staged_heads = Some(heads);
        Ok(())
    }

    /// Start the outbox log over from `durable`, the heads the sedimentree
    /// now holds. The file goes away, but `staged_heads` stays set to that
    /// point, so the next stage appends the changes since it rather than
    /// rewriting the whole note — which is what the next keystroke after
    /// every save would otherwise cost, growing with the note.
    ///
    /// Skips when the doc has moved past `durable`: those newer changes are
    /// in the log and nowhere else yet, so the log has to stay.
    async fn truncate_outbox(&self, id: DocId, durable: &[ChangeHash]) {
        let outbox = self.outbox_lock(id);
        let _outbox = outbox.lock().await;
        let Ok(state) = self.doc_state(id).await else {
            return;
        };
        let mut guard = state.lock().await;
        if guard.doc.get_heads() != durable {
            return;
        }
        let path = self.outbox_path(id);
        cpu_heavy(|| std::fs::remove_file(&path)).ok();
        sync_dir(&path);
        guard.staged_heads = Some(durable.to_vec());
    }

    pub async fn set_apply_incoming(self: &Arc<Self>, enabled: bool) {
        self.apply_incoming.store(enabled, Ordering::Relaxed);
        if !enabled {
            return;
        }
        let ids = std::mem::take(&mut *self.deferred_applies.lock().await);
        let repo = self.clone();
        tokio::spawn(async move {
            for id in ids {
                if repo.docs.lock().await.get(&id).is_none() {
                    continue;
                }
                if let Err(e) = repo.apply_new_blobs(id).await {
                    tracing::warn!(doc = %id.to_url(), error = %e, "future changes failed to apply");
                }
            }
        });
    }

    pub async fn set_send_changes(self: &Arc<Self>, enabled: bool) {
        self.send_changes.store(enabled, Ordering::Relaxed);
        if !enabled {
            return;
        }
        let ids = std::mem::take(&mut *self.deferred_sends.lock().await);
        let repo = self.clone();
        tokio::spawn(async move {
            for id in ids {
                if repo.docs.lock().await.get(&id).is_none() {
                    continue;
                }
                match repo.save_doc(id).await {
                    Ok(_) => repo.request_sync_forced(id).await,
                    Err(e) => {
                        tracing::warn!(doc = %id.to_url(), error = %e, "staged changes failed to publish")
                    }
                }
            }
        });
    }

    pub fn is_applying_incoming(&self) -> bool {
        self.apply_incoming.load(Ordering::Relaxed)
    }

    pub fn is_sending_changes(&self) -> bool {
        self.send_changes.load(Ordering::Relaxed)
    }

    pub async fn stored_doc(&self, id: DocId) -> Result<Automerge> {
        let batch = self.stored_batch(id).await?;
        let mut doc = Automerge::new();
        load_blob_batch(&mut doc, batch.commits, batch.fragments)?;
        Ok(doc)
    }

    pub async fn pending_change_count(&self, id: DocId) -> u32 {
        let Ok(stored) = self.stored_doc(id).await else {
            return 0;
        };
        let Some(state) = self.docs.lock().await.get(&id).cloned() else {
            return 0;
        };
        let current: HashSet<_> = state
            .lock()
            .await
            .doc
            .get_changes(&[])
            .into_iter()
            .map(|change| change.hash())
            .collect();
        stored
            .get_changes(&[])
            .into_iter()
            .filter(|change| !current.contains(&change.hash()))
            .count() as u32
    }

    pub fn local_server_port(&self) -> Option<u16> {
        self.local_port
    }

    pub fn local_http_url(&self) -> Option<String> {
        self.local_port
            .map(|port| format!("http://127.0.0.1:{port}"))
    }

    fn iroh_endpoint(&self) -> Option<Arc<iroh::Endpoint>> {
        self.iroh_endpoint.lock().unwrap().clone()
    }

    pub fn iroh_node_id(&self) -> Option<String> {
        self.iroh_endpoint().map(|ep| ep.id().to_string())
    }

    /// What you hand a friend: both of this device's public keys, the iroh one
    /// that says where to dial and the subduction one that says who will answer.
    pub fn iroh_friend_code(&self) -> Option<String> {
        let peer_id = PeerId::from(self.signer.verifying_key());
        self.iroh_endpoint()
            .map(|ep| format!("{}:{peer_id}", ep.id()))
    }

    /// Peer-to-peer sync is off until she turns it on. Binding the endpoint
    /// reaches for a relay, so it never happens on the startup path.
    pub async fn set_iroh_enabled(self: &Arc<Self>, enabled: bool) -> Result<()> {
        let _lifecycle = self.iroh_lifecycle.lock().await;
        if enabled == self.iroh_endpoint().is_some() {
            return Ok(());
        }
        if enabled {
            self.start_iroh().await?;
        } else {
            let endpoint = self.iroh_endpoint.lock().unwrap().take();
            if let Some(ep) = endpoint {
                ep.close().await;
            }
        }
        let _ = self.events.send(RepoEvent::PeersChanged);
        Ok(())
    }

    /// The accept loop ends on its own when the endpoint closes, so disabling
    /// only has to drop it.
    async fn start_iroh(self: &Arc<Self>) -> Result<()> {
        let key = load_or_create_iroh_key(&self.iroh_key_path)?;
        let endpoint = Arc::new(
            iroh::Endpoint::builder(iroh::endpoint::presets::N0)
                .secret_key(key)
                .alpns(vec![subduction_iroh::ALPN.to_vec()])
                .bind()
                .await
                .context("binding iroh endpoint")?,
        );
        tracing::info!(node_id = %endpoint.id(), "iroh endpoint bound");
        *self.iroh_endpoint.lock().unwrap() = Some(endpoint.clone());
        tokio::spawn(accept_iroh_peer(endpoint, self.clone()));
        let dialer = self.clone();
        tokio::spawn(async move {
            for peer in dialer.iroh_peers() {
                if !peer.added {
                    continue;
                }
                let code = match &peer.peer_id {
                    Some(peer_id) => format!("{}:{peer_id}", peer.node_id),
                    None => peer.node_id.clone(),
                };
                let dial = async {
                    let (node_id, expected) = parse_friend_code(&code)?;
                    dialer.dial_iroh_peer(node_id, expected).await
                };
                if let Err(e) = dial.await {
                    tracing::warn!(peer = %peer.node_id, error = %e, "iroh: dialing saved peer failed");
                }
            }
        });
        Ok(())
    }

    /// Every peer we know about. Not-added peers are ones who dialed us — the
    /// UI offers them as suggestions.
    pub fn iroh_peers(&self) -> Vec<IrohPeerEntry> {
        let peers = self.peers.lock().unwrap();
        let entry = |added: bool| {
            move |(node_id, peer_id): (&String, &Option<String>)| IrohPeerEntry {
                node_id: node_id.clone(),
                peer_id: peer_id.clone(),
                added,
            }
        };
        peers
            .added
            .iter()
            .map(entry(true))
            .chain(peers.seen.iter().map(entry(false)))
            .collect()
    }

    pub fn forget_iroh_peer(&self, node_id: &str) {
        let mut peers = self.peers.lock().unwrap();
        let changed = peers.added.remove(node_id).is_some() | peers.seen.remove(node_id).is_some();
        if changed {
            self.write_peers(&peers);
            drop(peers);
            let _ = self.events.send(RepoEvent::PeersChanged);
        }
    }

    /// A peer dialed us. The handshake already proved which subduction key they
    /// hold, so the suggestion carries a full friend code.
    fn note_iroh_peer_seen(&self, node_id: String, peer_id: PeerId) {
        let mut peers = self.peers.lock().unwrap();
        let peer_id = Some(peer_id.to_string());
        if let Some(known) = peers.added.get_mut(&node_id) {
            if *known == peer_id {
                return;
            }
            *known = peer_id;
        } else if peers.seen.get(&node_id) == Some(&peer_id) {
            return;
        } else {
            peers.seen.insert(node_id.clone(), peer_id);
        }
        self.write_peers(&peers);
        drop(peers);
        tracing::info!(peer = %node_id, "iroh: peer dialed us");
        let _ = self.events.send(RepoEvent::PeersChanged);
    }

    fn write_peers(&self, peers: &Peers) {
        match serde_json::to_vec_pretty(peers) {
            Ok(json) => {
                if let Err(e) = cpu_heavy(|| std::fs::write(&self.peers_path, json)) {
                    tracing::warn!(error = %e, "iroh: writing peer list failed");
                }
            }
            Err(e) => tracing::warn!(error = %e, "iroh: encoding peer list failed"),
        }
    }

    pub async fn add_iroh_peer(self: &Arc<Self>, code: String) -> Result<()> {
        let (node_id, expected) = parse_friend_code(&code)?;
        let peer_id = self.dial_iroh_peer(node_id, expected).await?;
        {
            let mut peers = self.peers.lock().unwrap();
            let node_id = node_id.to_string();
            peers.seen.remove(&node_id);
            peers.added.insert(node_id, Some(peer_id.to_string()));
            self.write_peers(&peers);
        }
        let _ = self.events.send(RepoEvent::PeersChanged);
        Ok(())
    }

    /// Dials `node_id` and returns the subduction identity that answered. When
    /// the friend code named one, a different answer is an error — the code
    /// says who should be at that address.
    async fn dial_iroh_peer(
        self: &Arc<Self>,
        node_id: iroh::EndpointId,
        expected: Option<PeerId>,
    ) -> Result<PeerId> {
        let ep = self
            .iroh_endpoint()
            .ok_or_else(|| anyhow!("iroh endpoint not running"))?;
        if node_id == ep.id() {
            return Err(anyhow!("that's this device's own node id"));
        }
        let addr = iroh::EndpointAddr::from(node_id);
        let audience = expected.map_or_else(|| iroh_audience(&node_id), Audience::known);
        let result = subduction_iroh::client::connect(&ep, addr, &self.signer, audience)
            .await
            .map_err(|e| match e {
                subduction_iroh::error::ConnectError::Handshake(_) => anyhow!(
                    "{node_id} refused the handshake — the friend code may name the wrong peer or be out of date"
                ),
                e => anyhow!(e),
            })?;
        let node = self.core.clone();
        tokio::spawn(result.listener_task);
        tokio::spawn(result.sender_task);
        let mut quic = None;
        let mapped = result.authenticated.map(|c| {
            quic = Some(c.clone());
            MessageTransport::new(WsTransport::Iroh(c))
        });
        let peer = mapped.peer_id();
        if let Some(expected) = expected {
            if peer != expected {
                if let Some(quic) = quic {
                    quic.close();
                }
                return Err(anyhow!(
                    "{node_id} answered as {peer}, not {expected} as the friend code says"
                ));
            }
        }
        node.add_connection(mapped)
            .await
            .map_err(|e| anyhow!("add_connection failed: {e}"))?;
        self.ephemeral.subscribe_peer(peer).await;
        tracing::info!(node_id = %node_id, peer = %peer, "iroh: dialed peer");
        Ok(peer)
    }

    pub async fn start(
        data_dir: PathBuf,
        server_url: String,
        enable_iroh: bool,
    ) -> Result<Arc<Repo>> {
        let boot = std::time::Instant::now();
        std::fs::create_dir_all(&data_dir).context("creating data dir")?;
        let outbox_dir = data_dir.join("outbox");
        std::fs::create_dir_all(&outbox_dir).context("creating outbox dir")?;
        let iroh_key_path = data_dir.join("iroh.key");
        let peers_path = data_dir.join("iroh-peers.json");
        let signer = load_or_create_signer(&data_dir.join("identity.seed"))?;
        let storage =
            FsStorage::new(data_dir.join("sedimentree")).context("opening sedimentree storage")?;
        tracing::info!(
            elapsed_ms = boot.elapsed().as_millis(),
            "repo storage opened"
        );
        let (stored_tx, mut stored_rx) = mpsc::channel(OBSERVER_QUEUE);
        let (heads_tx, mut heads_rx) = mpsc::channel(OBSERVER_QUEUE);
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
            outbox_dir,
            docs: Mutex::new(HashMap::new()),
            last_touched: std::sync::Mutex::new(HashMap::new()),
            pins: std::sync::Mutex::new(HashMap::new()),
            syncs: Mutex::new(HashMap::new()),
            pending_saves: Mutex::new(HashMap::new()),
            last_server_heads: Mutex::new(HashMap::new()),
            last_synced_local_heads: Mutex::new(HashMap::new()),
            deferred_applies: Mutex::new(HashSet::new()),
            deferred_sends: Mutex::new(HashSet::new()),
            outbox_locks: std::sync::Mutex::new(HashMap::new()),
            next_save: AtomicU64::new(0),
            events,
            connected: AtomicBool::new(false),
            connect_started: AtomicBool::new(false),
            apply_incoming: AtomicBool::new(true),
            send_changes: AtomicBool::new(true),
            local_port,
            iroh_key_path,
            iroh_endpoint: std::sync::Mutex::new(None),
            iroh_lifecycle: Mutex::new(()),
            sweep_lock: Mutex::new(()),
            peers: std::sync::Mutex::new(load_peers(&peers_path)),
            peers_path,
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
                    let node = node.clone();
                    let lp_handler = lp_handler.clone();
                    let relay_repo = relay_repo.clone();
                    tokio::spawn(async move {
                        let mut peek = [0u8; 4];
                        match tokio::time::timeout(LOCAL_PEEK_TIMEOUT, tcp.peek(&mut peek)).await {
                            Ok(Ok(n)) if n >= 3 => {}
                            _ => return,
                        }
                        if peek.starts_with(b"POST") || peek.starts_with(b"OPTI") {
                            let ephemeral = relay_repo.ephemeral.clone();
                            accept_local_http_peer(tcp, node, lp_handler, ephemeral).await;
                        } else {
                            accept_local_peer(tcp, node, relay_repo, peer_id, audience).await;
                        }
                    });
                }
            });
        }

        {
            let repo = repo.clone();
            tokio::spawn(async move {
                while let Some(batch) = stored_rx.recv().await {
                    let id = DocId::from_sedimentree_id(batch.sedimentree_id);
                    if !repo.apply_incoming.load(Ordering::Relaxed) && repo.doc_has_heads(id).await
                    {
                        repo.deferred_applies.lock().await.insert(id);
                        let _ = repo.events.send(RepoEvent::SyncEvent(format!(
                            "{}: changes waiting in the future",
                            short(id)
                        )));
                        continue;
                    }
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
        {
            let repo = repo.clone();
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(EVICT_SWEEP_INTERVAL).await;
                    repo.sweep_idle_docs(EVICT_IDLE).await;
                }
            });
        }
        repo.start_storage_load(enable_iroh);
        Ok(repo)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<RepoEvent> {
        self.events.subscribe()
    }

    /// Drops loose commits that a fragment already covers, tree by tree.
    ///
    /// Nothing else ever reclaims them: subduction only deletes loose commits
    /// when a whole document is destroyed, so every commit ever written stays
    /// on disk even once it has been bundled. `Sedimentree::minimize` decides
    /// what is redundant — the same rule sync uses — so a commit is only
    /// removed when the tree can still be rebuilt without it.
    pub async fn reclaim_loose_commits(&self) -> Result<(u64, u64)> {
        let ids = <ObservedStorage as Storage<Sendable>>::load_all_sedimentree_ids(&self.storage)
            .await
            .map_err(|e| anyhow::anyhow!("listing sedimentrees: {e}"))?;
        let trees = ids.len() as u64;
        let mut dropped = 0u64;
        for id in ids {
            dropped += self.reclaim_doc(DocId::from_sedimentree_id(id)).await;
        }
        tracing::info!(trees, dropped, "reclaimed loose commits");
        Ok((trees, dropped))
    }

    /// One doc's worth of the same pass, using automerge as the source of
    /// truth: any persisted hash the doc no longer reports is absorbed, so
    /// dropping it is provably safe.
    ///
    /// Only runs against a resident, hydrated doc. A doc still loading reports
    /// no commits, and comparing that against what is on disk would read as
    /// "everything is absorbed" and delete live data.
    pub(crate) async fn reclaim_doc(&self, id: DocId) -> u64 {
        let sid = id.sedimentree_id();
        let Some(shared) = self.docs.lock().await.get(&id).cloned() else {
            return 0;
        };
        let live: HashSet<ChangeHash> = {
            let state = shared.lock().await;
            if state.doc.get_heads().is_empty() {
                return 0;
            }
            let collected = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                state
                    .doc
                    .fragments(0..)
                    .into_iter()
                    .map(|f| f.head)
                    .collect()
            }));
            match collected {
                Ok(live) => live,
                Err(_) => {
                    tracing::warn!(doc = %id.to_url(), "fragment walk panicked; skipping reclaim");
                    return 0;
                }
            }
        };
        if live.is_empty() {
            return 0;
        }
        let commits = match <ObservedStorage as Storage<Sendable>>::load_loose_commit_metas(
            &self.storage,
            sid,
        )
        .await
        {
            Ok(commits) => commits,
            Err(e) => {
                tracing::warn!(error = %e, "loading loose commits failed");
                return 0;
            }
        };
        let absorbed: Vec<_> = commits
            .into_iter()
            .map(|commit| commit.head())
            .filter(|head| !live.contains(&ChangeHash(*head.as_bytes())))
            .collect();
        let dropped: u64 = futures::stream::iter(absorbed)
            .map(|head| async move {
                match <ObservedStorage as Storage<Sendable>>::delete_loose_commit(
                    &self.storage,
                    sid,
                    head,
                )
                .await
                {
                    Ok(()) => 1,
                    Err(e) => {
                        tracing::warn!(error = %e, "deleting loose commit failed");
                        0
                    }
                }
            })
            .buffer_unordered(RECLAIM_DELETE_CONCURRENCY)
            .fold(0u64, |total, n| async move { total + n })
            .await;
        if dropped > 0 {
            let mut state = shared.lock().await;
            state.stored_commits.retain(|hash| live.contains(hash));
        }
        dropped
    }

    pub fn announce_notes_prefetched(&self) {
        let _ = self.events.send(RepoEvent::NotesPrefetched);
    }

    /// Reads what is on disk, then says so and dials out. Owning the order here
    /// means no caller has to judge when the local load is done.
    fn start_storage_load(self: &Arc<Self>, enable_iroh: bool) {
        let repo = self.clone();
        tokio::spawn(async move {
            match <ObservedStorage as Storage<Sendable>>::load_all_sedimentree_ids(&repo.storage)
                .await
            {
                Ok(ids) => tracing::info!(count = ids.len(), "local storage enumerated"),
                Err(e) => tracing::warn!(error = %e, "local storage enumeration failed"),
            }
            let _ = repo.events.send(RepoEvent::StorageLoaded);
            repo.start_connect_loop_if_needed();
            if enable_iroh {
                if let Err(error) = repo.set_iroh_enabled(true).await {
                    tracing::warn!(%error, "iroh endpoint failed to start; peer-to-peer sync unavailable");
                }
            }
        });
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

    pub(crate) fn start_connect_loop_if_needed(self: &Arc<Self>) {
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
        // Surface connect failures in the app's sync log, but only when the
        // error changes — the retry loop would otherwise drown doc events.
        let mut last_error: Option<String> = None;
        loop {
            let audience = Audience::discover(host.as_bytes());
            match TokioWebSocketClient::new(uri.clone(), self.signer.clone(), audience).await {
                Ok((authenticated, listener_task, sender_task, keepalive_task)) => {
                    let peer_id = authenticated.peer_id();
                    tracing::info!(peer = %peer_id, "connected to sync server");
                    last_error = None;
                    let connected_at = tokio::time::Instant::now();
                    let listener = tokio::spawn(listener_task.into_future());
                    let sender = tokio::spawn(sender_task.into_future());
                    let keepalive = tokio::spawn(async move {
                        keepalive_task.await;
                    });
                    let mut dialed = None;
                    let transport = authenticated.map(|c| {
                        dialed = Some(c.clone());
                        MessageTransport::new(WsTransport::Dialed(Box::new(c)))
                    });
                    if let Err(e) = self.core.add_connection(transport).await {
                        tracing::error!(error = %e, "failed to register connection");
                        listener.abort();
                        if let Some(c) = dialed {
                            let _ = Transport::<Sendable>::disconnect(&c).await;
                        }
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
                    let message = format!("sync server unreachable: {e}");
                    if last_error.as_deref() != Some(message.as_str()) {
                        last_error = Some(message.clone());
                        let _ = self.events.send(RepoEvent::SyncEvent(message));
                    }
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
        let heads_set: BTreeSet<CommitId> = heads.iter().cloned().collect();
        if self.docs.lock().await.get(&id).is_none() {
            // An evicted (or never-opened) doc still gets its announced changes
            // pulled into storage. No materialization: the blobs land on disk,
            // the stored-batch loop emits DocChanged, and whoever cares reads
            // the doc back on demand.
            {
                let mut last = self.last_server_heads.lock().await;
                if last.get(&id) == Some(&heads_set) {
                    return;
                }
                last.insert(id, heads_set.clone());
            }
            let repo = self.clone();
            tokio::spawn(async move {
                let outcome =
                    repo.core
                        .sync_with_all_peers(id.sedimentree_id(), true, SYNC_TIMEOUT)
                        .await
                        .map(|peers| {
                            classify_sync(peers.values().map(|(succeeded, stats, _)| {
                                (*succeeded, stats.total_received() > 0)
                            }))
                        });
                if !matches!(outcome, Ok(SyncOutcome::Succeeded { .. })) {
                    // Forget the heads so the server's next announcement retries.
                    let mut last = repo.last_server_heads.lock().await;
                    if last.get(&id) == Some(&heads_set) {
                        last.remove(&id);
                    }
                }
            });
            return;
        }
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
        if !self.apply_incoming.load(Ordering::Relaxed) && self.doc_has_heads(id).await {
            self.last_server_heads.lock().await.insert(id, heads_set);
            self.request_sync_forced(id).await;
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
        self.last_server_heads.lock().await.insert(id, heads_set);
        if still_missing {
            self.request_sync_forced(id).await;
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
        if outcome.data_received()
            && (self.apply_incoming.load(Ordering::Relaxed) || !self.doc_has_heads(id).await)
        {
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
        if !self.send_changes.load(Ordering::Relaxed) && self.outbox_path(id).exists() {
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
                let exhausted = failures >= HEAL_MAX_ATTEMPTS;
                drop(syncs);
                if exhausted {
                    tokio::time::sleep(HEAL_DELAY).await;
                    failures = 0;
                }
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
        // Fragments arriving from a peer cover commits this device may still be
        // holding loose, so the same reclaim runs on receive as on save.
        let received_fragments = !batch.fragments.is_empty();
        let sid = batch.sedimentree_id;
        let (advanced, failed) = {
            let Some(state) = self.docs.lock().await.get(&id).cloned() else {
                // Untracked doc: the blobs are on disk but nothing in memory
                // advanced. Announce the change anyway so the search index and
                // sidebar re-read the doc — that read re-materializes it.
                if count > 0 {
                    let _ = self.events.send(RepoEvent::DocChanged(id));
                }
                return Ok(false);
            };
            let mut state = state.lock().await;
            cpu_heavy(|| apply_batch_to_state(&mut state, batch, id))
        };
        self.emit_batch_events(id, count, advanced, failed);
        if received_fragments {
            let _ = sid;
            self.reclaim_doc(id).await;
        }
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
        let muted = !self.send_changes.load(Ordering::Relaxed);
        if muted {
            let synced_before = {
                let state = shared.lock().await;
                !state.stored_commits.is_empty() || !state.stored_fragments.is_empty()
            };
            if synced_before {
                self.stage_doc(id).await?;
                self.deferred_sends.lock().await.insert(id);
                return Ok(false);
            }
        }
        let (ingested, ingested_heads) = {
            let state = shared.lock().await;
            let heads = state.doc.get_heads();
            let ingested = cpu_heavy(|| {
                ingest(
                    &state.doc,
                    sid,
                    &state.stored_commits,
                    &state.stored_fragments,
                )
            });
            (ingested, heads)
        };
        let Some(ingested) = ingested else {
            tracing::warn!(doc = %id.to_url(), "fragment ingest failed; staging to outbox");
            if let Err(e) = self.stage_doc(id).await {
                tracing::warn!(doc = %id.to_url(), error = %e, "staging after failed ingest failed");
            }
            return Ok(false);
        };
        if ingested.commits.is_empty() && ingested.fragments.is_empty() {
            if !ingested.skipped && !muted {
                self.truncate_outbox(id, &ingested_heads).await;
            }
            return Ok(false);
        }

        let Ingested {
            commits,
            fragments,
            commit_heads,
            fragment_heads,
            skipped,
        } = ingested;
        self.core
            .store_built_batch(sid, commits, fragments)
            .await
            .map_err(|e| anyhow!("store_built_batch failed: {e}"))?;

        let wrote_fragments = !fragment_heads.is_empty();
        {
            let mut state = shared.lock().await;
            state.stored_commits.extend(commit_heads);
            state.stored_fragments.extend(fragment_heads);
        }
        if muted {
            self.stage_doc(id).await?;
            self.deferred_sends.lock().await.insert(id);
        } else if !skipped {
            self.truncate_outbox(id, &ingested_heads).await;
        }
        if wrote_fragments {
            self.reclaim_doc(id).await;
        }

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
        catching(|| init(&mut doc))?;
        self.docs.lock().await.insert(id, DocState::shared(doc));
        self.touch(id);
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
            catching(|| f(&mut state.doc))?
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
            catching(|| {
                if state.doc.get_heads() == heads {
                    f(&mut state.doc)
                } else {
                    let mut fork = state.doc.fork_at(&heads)?;
                    let before = fork.get_heads();
                    let value = f(&mut fork)?;
                    if fork.get_heads() != before {
                        state.doc.merge(&mut fork)?;
                    }
                    Ok(value)
                }
            })?
        };
        if self.save_doc(id).await? {
            self.request_sync(id).await;
        }
        Ok(value)
    }

    /// Like `change_doc_at`, but only the sedimentree ingest is debounced.
    ///
    /// The edit is durable before this returns — it goes into the outbox log
    /// on the way through. What gets deferred is building fragments, which
    /// costs tens of milliseconds and climbs with the note's history, so it
    /// can't sit in front of every character.
    pub async fn change_doc_at_deferred_ingest<F, T>(
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
            catching(|| {
                if heads.is_empty() || state.doc.get_heads() == heads {
                    f(&mut state.doc)
                } else {
                    let mut fork = state.doc.fork_at(&heads)?;
                    let before = fork.get_heads();
                    let value = f(&mut fork)?;
                    if fork.get_heads() != before {
                        state.doc.merge(&mut fork)?;
                    }
                    Ok(value)
                }
            })?
        };
        // Durability is not what's deferred here — only the sedimentree
        // ingest is. The edit goes to the outbox log before this returns, so
        // there is no window where the caller has been told the change
        // landed while it lives only in memory.
        self.stage_doc(id).await?;
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
        let state = self
            .docs
            .lock()
            .await
            .get(&id)
            .cloned()
            .ok_or_else(|| anyhow!("unknown doc {}", id.to_url()))?;
        self.touch(id);
        Ok(state)
    }

    fn touch(&self, id: DocId) {
        self.last_touched.lock().unwrap().insert(id, Instant::now());
    }

    /// Keep a doc resident: a pinned doc is never swept by idle eviction.
    /// Pins are counted, so nested opens need matching unpins.
    pub fn pin_doc(&self, id: DocId) {
        *self.pins.lock().unwrap().entry(id).or_insert(0) += 1;
    }

    pub fn unpin_doc(&self, id: DocId) {
        let mut pins = self.pins.lock().unwrap();
        if let Some(count) = pins.get_mut(&id) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                pins.remove(&id);
            }
        }
    }

    fn is_pinned(&self, id: DocId) -> bool {
        self.pins.lock().unwrap().contains_key(&id)
    }

    /// Track a doc and populate it from local storage. The fresh doc's lock is
    /// held across the initial load so concurrent reads wait for the loaded doc
    /// instead of observing an empty one.
    async fn open_local(self: &Arc<Self>, id: DocId) {
        let mut guard = {
            let mut docs = self.docs.lock().await;
            if docs.contains_key(&id) {
                return;
            }
            let state = DocState::shared(Automerge::new());
            docs.insert(id, state.clone());
            self.touch(id);
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
        let merged_staged = cpu_heavy(|| {
            let Ok(bytes) = std::fs::read(self.outbox_path(id)) else {
                return false;
            };
            match merge_outbox_into(&mut guard.doc, &bytes) {
                Ok(()) => true,
                Err(e) => {
                    tracing::warn!(doc = %id.to_url(), error = %e, "staged doc failed to replay");
                    false
                }
            }
        });
        if merged_staged {
            // The log on disk covers everything the doc now holds that the
            // sedimentree doesn't, so record that as the baseline: without
            // it the first keystroke after opening a note rewrites the whole
            // thing instead of appending one change.
            let heads = guard.doc.get_heads();
            guard.staged_heads = Some(heads);
        }
        drop(guard);
        self.emit_batch_events(id, count, advanced, failed);
        if merged_staged {
            if let Err(e) = self.save_doc_now(id).await {
                tracing::warn!(doc = %id.to_url(), error = %e, "staged doc failed to persist");
            }
        }
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
        self.last_touched.lock().unwrap().remove(&id);
        self.syncs.lock().await.remove(&id);
        self.last_server_heads.lock().await.remove(&id);
        self.last_synced_local_heads.lock().await.remove(&id);
        self.ephemeral
            .unsubscribe(nonempty::NonEmpty::new(Topic::from(id.sedimentree_id())))
            .await;
    }

    /// Drop an idle doc's in-memory state, strictly: only when nothing is in
    /// flight for it and its exact heads are provably rebuildable from the
    /// sedimentree plus the outbox file. Anything doubtful skips — the doc
    /// just stays resident until the next sweep.
    pub async fn evict_doc(&self, id: DocId) -> bool {
        if self.is_pinned(id)
            || self.pending_saves.lock().await.contains_key(&id)
            || self.deferred_applies.lock().await.contains(&id)
            || self.deferred_sends.lock().await.contains(&id)
        {
            return false;
        }
        {
            let syncs = self.syncs.lock().await;
            if syncs
                .get(&id)
                .is_some_and(|slot| slot.running || slot.again)
            {
                return false;
            }
        }
        if self.docs.lock().await.get(&id).is_none() {
            return false;
        }
        if let Err(e) = self.save_doc_now(id).await {
            tracing::warn!(doc = %id.to_url(), error = %e, "flush before evict failed");
            if let Err(e) = self.stage_doc(id).await {
                tracing::warn!(doc = %id.to_url(), error = %e, "staging before evict failed; keeping doc resident");
                return false;
            }
        }
        // `staged_heads` is the proof, and asking it costs nothing. It is only
        // ever set to heads the disk can reproduce: by `stage_doc`, which has
        // just written a log that replays to them, or by `truncate_outbox`,
        // which drops the log because the sedimentree already holds them.
        // `open_local` performs that same replay, so a doc whose heads match
        // is a doc that comes back.
        let (heads, rebuildable) = {
            let Some(state) = self.docs.lock().await.get(&id).cloned() else {
                return false;
            };
            let guard = state.lock().await;
            let heads = guard.doc.get_heads();
            let rebuildable = guard.staged_heads.as_deref() == Some(heads.as_slice());
            (heads, rebuildable)
        };
        if !rebuildable {
            tracing::debug!(doc = %id.to_url(), "doc's heads are not on disk yet; keeping it resident");
            return false;
        }
        {
            let mut docs = self.docs.lock().await;
            let Some(state) = docs.get(&id).cloned() else {
                return false;
            };
            let Ok(guard) = state.try_lock() else {
                return false;
            };
            if guard.doc.get_heads() != heads || self.is_pinned(id) {
                return false;
            }
            drop(guard);
            docs.remove(&id);
        }
        self.last_touched.lock().unwrap().remove(&id);
        self.syncs.lock().await.remove(&id);
        self.last_server_heads.lock().await.remove(&id);
        self.last_synced_local_heads.lock().await.remove(&id);
        self.ephemeral
            .unsubscribe(nonempty::NonEmpty::new(Topic::from(id.sedimentree_id())))
            .await;
        tracing::debug!(doc = %id.to_url(), "evicted idle doc");
        true
    }

    /// Evict unpinned docs oldest first, taking each one `sweep_takes` allows.
    /// `Duration::ZERO` is the memory-pressure sweep: everything evictable goes.
    ///
    /// One at a time. The pressure signal repeats for as long as the pressure
    /// lasts, and a sweep already in flight is doing this one's work.
    pub async fn sweep_idle_docs(&self, idle: Duration) -> usize {
        let Ok(_sweeping) = self.sweep_lock.try_lock() else {
            tracing::debug!("idle sweep already running; skipping");
            return 0;
        };
        let before = headroom();
        let now = Instant::now();
        let ids: Vec<DocId> = self.docs.lock().await.keys().copied().collect();
        let mut candidates: Vec<(Duration, DocId)> = {
            let touched = self.last_touched.lock().unwrap();
            ids.into_iter()
                .map(|id| {
                    let age = touched
                        .get(&id)
                        .map_or(Duration::MAX, |t| now.duration_since(*t));
                    (age, id)
                })
                .collect()
        };
        candidates.sort_by(|a, b| b.0.cmp(&a.0));
        let mut resident = candidates.len();
        let mut evicted = 0;
        for (age, id) in candidates {
            // Re-read per doc: giving memory back is the point, so once the
            // sweep is out of the low-headroom margin it can stop.
            if !sweep_takes(age, idle, resident, headroom()) {
                break;
            }
            if self.evict_doc(id).await {
                evicted += 1;
                resident -= 1;
            }
        }
        let after = headroom();
        if evicted > 0 {
            tracing::info!(
                evicted,
                resident,
                before_mb = ?before.map(|b| b >> 20),
                after_mb = ?after.map(|b| b >> 20),
                "idle sweep"
            );
        } else if after.is_some_and(|free| free < LOW_HEADROOM) {
            // The one worth seeing in a crash report: headroom gone and
            // nothing evictable to give back.
            tracing::warn!(resident, free_mb = ?after.map(|b| b >> 20), "sweep freed nothing");
        }
        evicted
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
            .publish(EphemeralMessage::Ephemeral(Box::new(
                verified.into_signed(),
            )))
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

    /// Run every pending debounced save now, and report which docs gained
    /// data on disk. Local durability only — no network.
    async fn drain_pending_saves(&self) -> HashSet<DocId> {
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
                Err(e) => {
                    tracing::warn!(doc = %id.to_url(), error = %e, "pending save flush failed")
                }
            }
        }
        dirty
    }

    /// Get every debounced edit onto disk, without the network round trip
    /// `shutdown` waits for. This is the suspend path, not the exit path:
    /// iOS suspends an app in the background and may kill it later without
    /// ever sending `willTerminate`, so a change still sitting in
    /// `pending_saves` at that moment is typed text the user never gets back.
    pub async fn flush_pending_saves(&self) {
        self.drain_pending_saves().await;
    }

    /// Flush all pending saves and do a best-effort final sync before the app
    /// exits. Should be called from applicationWillTerminate / sceneDidDisconnect.
    pub async fn shutdown(self: &Arc<Self>) {
        let mut dirty = self.drain_pending_saves().await;
        dirty.extend(
            self.syncs
                .lock()
                .await
                .iter()
                .filter(|(_, slot)| slot.running || slot.again)
                .map(|(id, _)| *id),
        );
        if !self.send_changes.load(Ordering::Relaxed) {
            dirty.retain(|id| !self.outbox_path(*id).exists());
        }
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
pub(crate) mod fuzz;

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

    /// What one sedimentree record costs to write, and how many records a
    /// save carries. Run with `--ignored --nocapture`.
    ///
    /// This is the number that decides whether a keystroke can write
    /// straight into the sedimentree: it is flat in the note's history and
    /// dominated by the compound write's four fsyncs, two file creates and
    /// two renames, so it does not shrink in release and does not amortize
    /// until several records share a batch.
    #[tokio::test]
    #[ignore]
    async fn bench_loose_commit_write() {
        use std::time::{Duration, Instant};

        for prior in [100usize, 3000] {
            let (_dir, repo) = test_repo().await;
            let id = repo.create_doc(|_| Ok(())).await.unwrap();
            let mut at = 0usize;
            for _ in 0..prior {
                type_one(&repo, id, at).await;
                at += 1;
            }
            repo.save_doc_now(id).await.unwrap();
            let sid = id.sedimentree_id();

            let n = 20u32;
            let mut store = Duration::ZERO;
            let mut commits = 0usize;
            let mut frags = 0usize;

            for _ in 0..n {
                type_one(&repo, id, at).await;
                at += 1;
                let ingested = {
                    let state = repo.doc_state(id).await.unwrap();
                    let g = state.lock().await;
                    ingest(&g.doc, sid, &g.stored_commits, &g.stored_fragments).unwrap()
                };
                commits += ingested.commits.len();
                frags += ingested.fragments.len();
                let Ingested {
                    commits: c,
                    fragments: f,
                    commit_heads,
                    fragment_heads,
                    ..
                } = ingested;
                let t = Instant::now();
                repo.core.store_built_batch(sid, c, f).await.unwrap();
                store += t.elapsed();
                let state = repo.doc_state(id).await.unwrap();
                let mut g = state.lock().await;
                g.stored_commits.extend(commit_heads);
                g.stored_fragments.extend(fragment_heads);
            }

            println!(
                "{prior:>5} prior: store_built_batch {:>11?} for {:.2} commits + {:.2} fragments per save",
                store / n,
                commits as f64 / n as f64,
                frags as f64 / n as f64
            );
        }
    }

    /// Does automerge form real fragments during ordinary editing? The
    /// synthetic loose-batching in `ingest_loose_batch` exists because
    /// "ordinary editing never reached the batch size and left everything
    /// loose for good". Run with `--ignored --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn bench_natural_fragment_formation() {
        for total in [500usize, 2000, 8000] {
            let (_dir, repo) = test_repo().await;
            let id = repo.create_doc(|_| Ok(())).await.unwrap();
            for at in 0..total {
                type_one(&repo, id, at).await;
            }
            let state = repo.doc_state(id).await.unwrap();
            let g = state.lock().await;
            let mut by_level = std::collections::BTreeMap::new();
            for f in g.doc.fragments(0..) {
                *by_level.entry(f.level).or_insert(0usize) += 1;
            }
            println!("{total:>5} changes -> fragments by level: {by_level:?}");
        }
    }

    /// Where a save's time goes, and how it scales with a note's history.
    /// Writing is roughly `full save - ingest`, since `save_doc_now` runs its
    /// own ingest.
    ///
    /// **Run this with `--release`.** A debug build inflates `fragments(0..)`
    /// by 10-15x and makes the enumeration look like the dominant cost when it
    /// is not. In release it is 1.5ms for a 10k-change note, which matches
    /// what automerge-repo's subduction source assumes ("cheap: a few ms even
    /// at 12k changes").
    ///
    /// `ingest` is almost entirely `fragments(0..)`. It grows with the note's
    /// history, because automerge exports metadata for every fragment at every
    /// level before `ingest` skips the ones already stored. The
    /// `fragments(0..1)` column is the same call restricted to the loose tail.
    /// Reading only that level would be cheaper, but a change whose own
    /// `fragment_level` is >= 1 never appears there, so it would miss records
    /// that must be stored — and at 1.5ms the enumeration is not worth
    /// trading correctness for. Bundling is the half that has to stay behind
    /// the already-stored filter; see `ingest`.
    #[tokio::test]
    #[ignore]
    async fn bench_ingest_breakdown() {
        use std::time::{Duration, Instant};

        for prior in [100usize, 1000, 3000, 10000] {
            let (_dir, repo) = test_repo().await;
            let id = repo.create_doc(|_| Ok(())).await.unwrap();
            let mut at = 0usize;
            for _ in 0..prior {
                type_one(&repo, id, at).await;
                at += 1;
            }
            repo.save_doc_now(id).await.unwrap();
            let sid = id.sedimentree_id();

            let n = 20u32;
            let mut enumerate = Duration::ZERO;
            let mut loose_only = Duration::ZERO;
            let mut ingest_only = Duration::ZERO;
            let mut whole = Duration::ZERO;

            for _ in 0..n {
                type_one(&repo, id, at).await;
                at += 1;

                {
                    let state = repo.doc_state(id).await.unwrap();
                    let g = state.lock().await;
                    let t = Instant::now();
                    let _ = g.doc.fragments(0..).len();
                    enumerate += t.elapsed();

                    let t = Instant::now();
                    let _ = g.doc.fragments(0..1).len();
                    loose_only += t.elapsed();

                    let t = Instant::now();
                    let _ = ingest(&g.doc, sid, &g.stored_commits, &g.stored_fragments);
                    ingest_only += t.elapsed();
                }

                let t = Instant::now();
                repo.save_doc_now(id).await.unwrap();
                whole += t.elapsed();
            }

            println!(
                "{prior:>6} prior: fragments(0..) {:>11?} | fragments(0..1) {:>11?} | ingest {:>11?} | full save {:>11?}",
                enumerate / n,
                loose_only / n,
                ingest_only / n,
                whole / n
            );
        }
    }

    /// Not a test — run with `--ignored --nocapture` to compare what each
    /// durability strategy costs per keystroke as a note accumulates history.
    #[tokio::test]
    #[ignore]
    async fn bench_write_paths() {
        use std::time::Instant;

        for prior in [100usize, 1000, 3000] {
            let (_dir, repo) = test_repo().await;
            let id = repo.create_doc(|_| Ok(())).await.unwrap();
            let mut at = 0usize;
            for _ in 0..prior {
                type_one(&repo, id, at).await;
                at += 1;
            }
            repo.save_doc_now(id).await.unwrap();
            drop_outbox_baseline(&repo, id).await;

            let n = 30u32;

            let t = Instant::now();
            for _ in 0..n {
                type_one(&repo, id, at).await;
                at += 1;
                repo.save_doc_now(id).await.unwrap();
            }
            let save = t.elapsed() / n;

            repo.stage_doc(id).await.unwrap();
            let t = Instant::now();
            for _ in 0..n {
                type_one(&repo, id, at).await;
                at += 1;
                repo.stage_doc(id).await.unwrap();
            }
            let append = t.elapsed() / n;

            let t = Instant::now();
            for _ in 0..n {
                type_one(&repo, id, at).await;
                at += 1;
                drop_outbox_baseline(&repo, id).await;
                repo.stage_doc(id).await.unwrap();
            }
            let restage = t.elapsed() / n;

            println!(
                "{prior:>5} prior changes: sedimentree save {save:>12?} | outbox append {append:>12?} | outbox re-stage {restage:>12?}"
            );
        }
    }

    /// Force the outbox back to having no baseline, so the benchmark can
    /// price a full rewrite against an append.
    async fn drop_outbox_baseline(repo: &Arc<Repo>, id: DocId) {
        std::fs::remove_file(repo.outbox_path(id)).ok();
        if let Ok(state) = repo.doc_state(id).await {
            state.lock().await.staged_heads = None;
        }
    }

    /// Mutate the in-memory doc only, no persistence, so a benchmark can time
    /// one storage strategy without another one inside the measurement.
    async fn type_one(repo: &Arc<Repo>, id: DocId, at: usize) {
        let state = repo.doc_state(id).await.unwrap();
        let mut state = state.lock().await;
        let mut tx = state.doc.transaction();
        let obj = match tx.get(ROOT, "text").unwrap() {
            Some((_, o)) => o,
            None => tx
                .put_object(ROOT, "text", automerge::ObjType::Text)
                .unwrap(),
        };
        tx.splice_text(&obj, at, 0, "x").unwrap();
        tx.commit();
    }

    fn put(doc: &mut Automerge, key: &str, value: impl Into<automerge::ScalarValue>) {
        let mut tx = doc.transaction();
        tx.put(ROOT, key, value).unwrap();
        tx.commit();
    }

    async fn test_repo() -> (TempDir, Arc<Repo>) {
        let dir = tempfile::tempdir().unwrap();
        let repo = Repo::start(dir.path().to_path_buf(), "http://[".to_string(), false)
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
    fn friend_codes_carry_both_public_keys() {
        let node = "5b47d9301f15173c1b34348ae976282d0274ac413f364595bcfab257b86d2f99";
        let peer = "1".repeat(64);
        let (parsed_node, parsed_peer) = parse_friend_code(&format!(" {node}:{peer}\n")).unwrap();
        assert_eq!(parsed_node.to_string(), node);
        assert_eq!(parsed_peer.unwrap().to_string(), peer);

        assert_eq!(parse_friend_code(node).unwrap().1, None);
        assert!(parse_friend_code(&format!("{node}:beep")).is_err());
        assert!(parse_friend_code("beep").is_err());
    }

    async fn iroh_test_repo() -> (TempDir, Arc<Repo>) {
        let (dir, repo) = test_repo().await;
        repo.set_iroh_enabled(true).await.unwrap();
        (dir, repo)
    }

    /// Dialing by node id goes through iroh discovery, so the endpoint being
    /// dialed has to have published its address before the test can find it.
    async fn wait_until_dialable(repo: &Repo) {
        timeout(
            Duration::from_secs(20),
            repo.iroh_endpoint().unwrap().online(),
        )
        .await
        .expect("iroh endpoint should come online");
    }

    #[tokio::test]
    async fn iroh_stays_off_until_it_is_turned_on() {
        let (dir, repo) = test_repo().await;
        assert!(repo.iroh_node_id().is_none());
        assert!(!dir.path().join("iroh.key").exists());
    }

    /// Turning it off and on again keeps the same node id, so a friend code
    /// she has already shared stays good.
    #[tokio::test]
    async fn iroh_keeps_its_node_id_across_a_toggle() {
        let (dir, repo) = test_repo().await;
        if repo.set_iroh_enabled(true).await.is_err() {
            return;
        }
        let node_id = repo.iroh_node_id().unwrap();
        assert!(dir.path().join("iroh.key").exists());
        repo.set_iroh_enabled(false).await.unwrap();
        assert!(repo.iroh_node_id().is_none());
        repo.set_iroh_enabled(true).await.unwrap();
        assert_eq!(repo.iroh_node_id().as_deref(), Some(node_id.as_str()));
        repo.set_iroh_enabled(false).await.unwrap();
    }

    /// Needs the network: dialing by node id goes through iroh discovery.
    #[tokio::test]
    #[ignore]
    async fn iroh_peers_handshake_and_remember_each_other() {
        let (_dir_a, a) = iroh_test_repo().await;
        let (_dir_b, b) = iroh_test_repo().await;
        wait_until_dialable(&a).await;
        wait_until_dialable(&b).await;

        a.add_iroh_peer(b.iroh_friend_code().unwrap())
            .await
            .unwrap();
        assert_eq!(
            a.iroh_peers()
                .into_iter()
                .map(|peer| (
                    format!("{}:{}", peer.node_id, peer.peer_id.unwrap()),
                    peer.added
                ))
                .collect::<Vec<_>>(),
            vec![(b.iroh_friend_code().unwrap(), true)]
        );

        let a_code = a.iroh_friend_code().unwrap();
        timeout(Duration::from_secs(5), async {
            loop {
                let seen: Vec<_> = b
                    .iroh_peers()
                    .into_iter()
                    .filter(|peer| !peer.added)
                    .filter_map(|peer| Some(format!("{}:{}", peer.node_id, peer.peer_id?)))
                    .collect();
                if seen == vec![a_code.clone()] {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .expect("b should see a's full friend code as a suggestion");
    }

    /// The friend code names who should answer; anyone else is refused.
    #[tokio::test]
    #[ignore]
    async fn dialing_refuses_a_peer_id_the_code_did_not_name() {
        let (_dir_a, a) = iroh_test_repo().await;
        let (_dir_b, b) = iroh_test_repo().await;
        wait_until_dialable(&a).await;
        wait_until_dialable(&b).await;
        let wrong = format!("{}:{}", b.iroh_node_id().unwrap(), "2".repeat(64));

        let error = a.add_iroh_peer(wrong).await.unwrap_err().to_string();
        assert!(error.contains("refused the handshake"), "{error}");
        assert!(a.iroh_peers().is_empty());
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

    /// The whole-blob path still owes its caller the same digest and a range
    /// covering the blob, or the per-blob retry reads the wrong bytes.
    #[test]
    fn a_single_blob_batch_is_taken_whole() {
        let mut source = Automerge::new().with_actor(ActorId::from([9; 16].as_slice()));
        put(&mut source, "value", "alone");
        let ingested = ingest(
            &source,
            DocId([9; 16]).sedimentree_id(),
            &HashSet::new(),
            &HashSet::new(),
        )
        .unwrap();
        assert_eq!(ingested.commits.len() + ingested.fragments.len(), 1);
        let commits: Vec<_> = ingested
            .commits
            .into_iter()
            .map(|(meta, blob)| StoredRecord { meta, blob })
            .collect();
        let expected = BlobMeta::new(&commits[0].blob).digest();
        let contents = commits[0].blob.as_slice().to_vec();

        let (bytes, parts) = concat_blob_batch(commits, Vec::new());
        assert_eq!(bytes, contents);
        assert_eq!(parts, vec![(expected, 0..contents.len())]);

        let mut loaded = Automerge::new();
        loaded.load_incremental(&bytes[parts[0].1.clone()]).unwrap();
        assert_eq!(loaded.get_heads(), source.get_heads());
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

        let stored = commits.len() + fragments.len();
        let mut loaded = Automerge::new();
        let applied = load_blob_batch(&mut loaded, commits, fragments).unwrap();

        assert_eq!(applied.len(), stored);
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

    /// Every record written has to correspond to a fragment automerge itself
    /// reports, at the matching level. A previous version of `ingest` batched
    /// level-0 runs into hand-built `AutomergeFragment`s — a head automerge
    /// never chose, `level: 0` stored as a fragment record, and every member
    /// declared a checkpoint — which put our sedimentree and the server's out
    /// of step. Automerge core owns the compaction policy.
    #[test]
    fn ingest_mirrors_automerge_fragment_levels() {
        let id = DocId([12; 16]);
        let sid = id.sedimentree_id();
        let mut source = Automerge::new().with_actor(ActorId::from([12; 16].as_slice()));
        for _ in 0..600 {
            let index = source.length(ROOT);
            put(&mut source, &format!("value-{index}"), index as i64);
        }

        let by_head: HashMap<ChangeHash, usize> = source
            .fragments(0..)
            .into_iter()
            .map(|f| (f.head, f.level))
            .collect();
        assert!(
            by_head.values().any(|level| *level > 0),
            "expected automerge to have formed at least one real fragment"
        );

        let ingested = ingest(&source, sid, &HashSet::new(), &HashSet::new()).unwrap();

        for head in &ingested.commit_heads {
            assert_eq!(
                by_head.get(head),
                Some(&0),
                "a loose commit must be a level-0 automerge fragment"
            );
        }
        for head in &ingested.fragment_heads {
            let level = by_head
                .get(head)
                .copied()
                .expect("a fragment record must have a head automerge reported");
            assert!(level > 0, "a fragment record must come from level >= 1");
        }
        assert_eq!(
            ingested.commit_heads.len() + ingested.fragment_heads.len(),
            by_head.len(),
            "every fragment automerge reports should be stored exactly once"
        );
    }

    /// The durability property, across the point where automerge forms a real
    /// fragment mid-stream: saving a few changes at a time and then loading
    /// only what was stored has to reproduce the doc.
    #[test]
    fn ingest_reconstructs_doc_across_fragment_formation() {
        let id = DocId([13; 16]);
        let sid = id.sedimentree_id();
        let mut source = Automerge::new().with_actor(ActorId::from([13; 16].as_slice()));

        let mut stored_commits = HashSet::new();
        let mut stored_fragments = HashSet::new();
        let mut commits = Vec::new();
        let mut fragments = Vec::new();

        for round in 0..120 {
            for _ in 0..5 {
                let index = source.length(ROOT);
                put(&mut source, &format!("value-{index}"), index as i64);
            }
            let ingested = ingest(&source, sid, &stored_commits, &stored_fragments).unwrap();
            assert!(!ingested.skipped, "round {round} failed to bundle");
            stored_commits.extend(ingested.commit_heads.iter().copied());
            stored_fragments.extend(ingested.fragment_heads.iter().copied());
            commits.extend(
                ingested
                    .commits
                    .into_iter()
                    .map(|(meta, blob)| StoredRecord { meta, blob }),
            );
            fragments.extend(
                ingested
                    .fragments
                    .into_iter()
                    .map(|(meta, blob)| StoredRecord { meta, blob }),
            );
        }

        assert!(
            !fragments.is_empty(),
            "600 changes should have formed at least one fragment record"
        );

        let mut loaded = Automerge::new();
        load_blob_batch(&mut loaded, commits, fragments).unwrap();
        assert_eq!(loaded.get_heads(), source.get_heads());
    }

    /// Re-ingesting with everything already stored writes nothing. This is
    /// what keeps a save O(what changed) rather than O(the note's history):
    /// bundling is the expensive half, and it sits behind this filter.
    #[test]
    fn ingest_skips_records_already_stored() {
        let id = DocId([14; 16]);
        let sid = id.sedimentree_id();
        let mut source = Automerge::new().with_actor(ActorId::from([14; 16].as_slice()));
        for _ in 0..600 {
            let index = source.length(ROOT);
            put(&mut source, &format!("value-{index}"), index as i64);
        }

        let first = ingest(&source, sid, &HashSet::new(), &HashSet::new()).unwrap();
        let stored_commits: HashSet<_> = first.commit_heads.iter().copied().collect();
        let stored_fragments: HashSet<_> = first.fragment_heads.iter().copied().collect();

        let second = ingest(&source, sid, &stored_commits, &stored_fragments).unwrap();
        assert!(second.commits.is_empty() && second.fragments.is_empty());

        put(&mut source, "one-more", 1);
        let third = ingest(&source, sid, &stored_commits, &stored_fragments).unwrap();
        assert_eq!(third.commits.len() + third.fragments.len(), 1);
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
    async fn staged_changes_publish_when_sending_resumes() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "value", "before");
                Ok(())
            })
            .await
            .unwrap();
        let before = repo.stored_batch(id).await.unwrap();
        let before_count = before.commits.len() + before.fragments.len();

        repo.set_send_changes(false).await;
        let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        repo.change_doc_at_deferred_ingest(id, heads, |doc| {
            put(doc, "value", "after");
            Ok(())
        })
        .await
        .unwrap();

        let staged = repo.stored_batch(id).await.unwrap();
        assert_eq!(staged.commits.len() + staged.fragments.len(), before_count);

        repo.set_send_changes(true).await;

        timeout(Duration::from_secs(2), async {
            loop {
                let published = repo.stored_batch(id).await.unwrap();
                if published.commits.len() + published.fragments.len() > before_count
                    && !repo.outbox_path(id).exists()
                {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn docs_created_while_muted_are_stored_locally() {
        let (_dir, repo) = test_repo().await;
        repo.set_send_changes(false).await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "value", "here");
                Ok(())
            })
            .await
            .unwrap();

        let stored = repo.stored_batch(id).await.unwrap();
        assert!(stored.commits.len() + stored.fragments.len() > 0);
        assert!(repo.outbox_path(id).exists());
        assert!(repo.deferred_sends.lock().await.contains(&id));

        repo.change_doc(id, |doc| {
            put(doc, "value", "edited");
            Ok(())
        })
        .await
        .unwrap();
        let after_edit = repo.stored_batch(id).await.unwrap();
        assert_eq!(
            after_edit.commits.len() + after_edit.fragments.len(),
            stored.commits.len() + stored.fragments.len()
        );
        assert!(repo.outbox_path(id).exists());
    }

    #[tokio::test]
    async fn incoming_changes_wait_until_application_resumes() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "local", "here");
                Ok(())
            })
            .await
            .unwrap();
        repo.set_apply_incoming(false).await;

        let mut remote = repo.read_doc(id, |doc| Ok(doc.fork())).await.unwrap();
        remote.set_actor(ActorId::from([31; 16].as_slice()));
        put(&mut remote, "remote", "waiting");
        let ingested = ingest(
            &remote,
            id.sedimentree_id(),
            &HashSet::new(),
            &HashSet::new(),
        )
        .unwrap();
        repo.core
            .store_built_batch(id.sedimentree_id(), ingested.commits, ingested.fragments)
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;

        let has_remote = repo
            .read_doc(id, |doc| Ok(doc.get(ROOT, "remote")?.is_some()))
            .await
            .unwrap();
        assert!(!has_remote);
        assert_eq!(repo.pending_change_count(id).await, 1);
        assert!(repo.deferred_applies.lock().await.contains(&id));

        let mut events = repo.subscribe();
        repo.set_apply_incoming(true).await;
        wait_for_change(&mut events, id).await;

        let has_remote = repo
            .read_doc(id, |doc| Ok(doc.get(ROOT, "remote")?.is_some()))
            .await
            .unwrap();
        assert!(has_remote);
        assert_eq!(repo.pending_change_count(id).await, 0);
        assert!(repo.deferred_applies.lock().await.is_empty());
    }

    #[tokio::test]
    async fn reenabling_apply_drains_only_recorded_docs() {
        let (_dir, repo) = test_repo().await;
        let mut ids = Vec::new();
        for n in 0u8..3 {
            let id = repo
                .create_doc(|doc| {
                    put(doc, "local", n.to_string());
                    Ok(())
                })
                .await
                .unwrap();
            ids.push(id);
        }
        let (a, b, c) = (ids[0], ids[1], ids[2]);
        repo.set_apply_incoming(false).await;

        for (id, actor) in [(a, 41u8), (b, 42u8)] {
            let mut remote = repo.read_doc(id, |doc| Ok(doc.fork())).await.unwrap();
            remote.set_actor(ActorId::from([actor; 16].as_slice()));
            put(&mut remote, "remote", "waiting");
            let ingested = ingest(
                &remote,
                id.sedimentree_id(),
                &HashSet::new(),
                &HashSet::new(),
            )
            .unwrap();
            repo.core
                .store_built_batch(id.sedimentree_id(), ingested.commits, ingested.fragments)
                .await
                .unwrap();
        }
        timeout(Duration::from_secs(2), async {
            loop {
                if repo.deferred_applies.lock().await.len() == 2 {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(*repo.deferred_applies.lock().await, HashSet::from([a, b]));

        repo.drop_doc(b).await;
        repo.set_apply_incoming(true).await;

        timeout(Duration::from_secs(2), async {
            loop {
                let applied = repo
                    .read_doc(a, |doc| Ok(doc.get(ROOT, "remote")?.is_some()))
                    .await
                    .unwrap();
                if applied {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert!(repo.deferred_applies.lock().await.is_empty());
        let untouched = repo
            .read_doc(c, |doc| Ok(doc.get(ROOT, "remote")?.is_some()))
            .await
            .unwrap();
        assert!(!untouched);
    }

    #[tokio::test]
    async fn reenabling_send_drains_only_recorded_docs() {
        let (_dir, repo) = test_repo().await;
        let mut ids = Vec::new();
        for n in 0u8..3 {
            let id = repo
                .create_doc(|doc| {
                    put(doc, "value", n.to_string());
                    Ok(())
                })
                .await
                .unwrap();
            ids.push(id);
        }
        let (a, b, c) = (ids[0], ids[1], ids[2]);
        let mut counts = HashMap::new();
        for id in [a, b, c] {
            let batch = repo.stored_batch(id).await.unwrap();
            counts.insert(id, batch.commits.len() + batch.fragments.len());
        }

        repo.set_send_changes(false).await;
        for id in [a, b] {
            let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
            repo.change_doc_at_deferred_ingest(id, heads, |doc| {
                put(doc, "value", "after");
                Ok(())
            })
            .await
            .unwrap();
            repo.save_doc(id).await.unwrap();
        }
        assert_eq!(*repo.deferred_sends.lock().await, HashSet::from([a, b]));

        repo.set_send_changes(true).await;

        timeout(Duration::from_secs(2), async {
            loop {
                let mut published = true;
                for id in [a, b] {
                    let batch = repo.stored_batch(id).await.unwrap();
                    published &= batch.commits.len() + batch.fragments.len() > counts[&id]
                        && !repo.outbox_path(id).exists();
                }
                if published {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert!(repo.deferred_sends.lock().await.is_empty());
        let batch = repo.stored_batch(c).await.unwrap();
        assert_eq!(batch.commits.len() + batch.fragments.len(), counts[&c]);
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

    async fn connected_pair() -> (TempDir, Arc<Repo>, TempDir, Arc<Repo>) {
        let dir_a = tempfile::tempdir().unwrap();
        let a = Repo::start(dir_a.path().to_path_buf(), "http://[".to_string(), false)
            .await
            .unwrap();
        let port = a.local_server_port().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let b = Repo::start(
            dir_b.path().to_path_buf(),
            format!("ws://127.0.0.1:{port}"),
            false,
        )
        .await
        .unwrap();
        assert!(b.wait_connected(Duration::from_secs(10)).await);
        (dir_a, a, dir_b, b)
    }

    async fn evict_when_settled(repo: &Arc<Repo>, id: DocId) {
        timeout(Duration::from_secs(10), async {
            while !repo.evict_doc(id).await {
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("doc should become evictable");
        assert!(repo.docs.lock().await.get(&id).is_none());
    }

    /// The chain push-notification and rule evaluation hang off: a change made
    /// on another device reaches this one while the doc is evicted. The blobs
    /// land in storage over a real loopback sync, DocChanged fires with nothing
    /// resident, and reading the doc rebuilds it with the new content.
    #[tokio::test]
    async fn remote_changes_wake_an_evicted_doc_end_to_end() {
        let (_da, a, _db, b) = connected_pair().await;
        let id = a
            .create_doc(|doc| {
                put(doc, "value", "first");
                Ok(())
            })
            .await
            .unwrap();
        b.ensure_doc(id).await.unwrap();
        assert!(b.wait_for_doc(id, Duration::from_secs(10)).await);
        evict_when_settled(&b, id).await;

        let mut events = b.subscribe();
        a.change_doc(id, |doc| {
            put(doc, "remote", "waiting");
            Ok(())
        })
        .await
        .unwrap();
        let expected = a.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        // The announcement a sync server would push for a doc b no longer
        // tracks: b must pull the blobs into storage without materializing.
        let announced: Vec<CommitId> = expected.iter().map(|h| CommitId::new(h.0)).collect();
        b.on_remote_heads(id.sedimentree_id(), announced).await;

        timeout(Duration::from_secs(10), async {
            loop {
                match events.recv().await.unwrap() {
                    RepoEvent::DocChanged(changed) if changed == id => {
                        let (heads, has_remote) = b
                            .read_doc(id, |doc| {
                                Ok((doc.get_heads(), doc.get(ROOT, "remote")?.is_some()))
                            })
                            .await
                            .unwrap();
                        if has_remote {
                            assert_eq!(heads, expected);
                            return;
                        }
                    }
                    _ => {}
                }
            }
        })
        .await
        .expect("evicted doc should wake on a remote change");
    }

    /// Same chain without the network: blobs stored for an untracked doc emit
    /// DocChanged so the index and sidebar re-read, and the read rebuilds the
    /// doc with the stored content.
    #[tokio::test]
    async fn stored_blobs_for_an_untracked_doc_emit_doc_changed() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "value", "first");
                Ok(())
            })
            .await
            .unwrap();
        let mut remote = repo.read_doc(id, |doc| Ok(doc.fork())).await.unwrap();
        remote.set_actor(ActorId::from([21; 16].as_slice()));
        put(&mut remote, "remote", "arrived");
        let expected = remote.get_heads();
        evict_when_settled(&repo, id).await;

        let mut events = repo.subscribe();
        let ingested = ingest(
            &remote,
            id.sedimentree_id(),
            &HashSet::new(),
            &HashSet::new(),
        )
        .unwrap();
        repo.core
            .store_built_batch(id.sedimentree_id(), ingested.commits, ingested.fragments)
            .await
            .unwrap();

        timeout(Duration::from_secs(5), async {
            loop {
                match events.recv().await.unwrap() {
                    RepoEvent::DocChanged(changed) if changed == id => {
                        let (heads, has_remote) = repo
                            .read_doc(id, |doc| {
                                Ok((doc.get_heads(), doc.get(ROOT, "remote")?.is_some()))
                            })
                            .await
                            .unwrap();
                        if has_remote {
                            assert_eq!(heads, expected);
                            return;
                        }
                    }
                    _ => {}
                }
            }
        })
        .await
        .expect("stored blobs for an untracked doc should announce themselves");
    }

    /// Eviction's proof that a doc is on disk. Break it and eviction stops
    /// happening at all, quietly.
    #[tokio::test]
    async fn a_save_leaves_the_staged_heads_on_the_docs_own_heads() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "first", "saved");
                Ok(())
            })
            .await
            .unwrap();
        repo.change_doc(id, |doc| {
            put(doc, "second", "also saved");
            Ok(())
        })
        .await
        .unwrap();
        repo.save_doc_now(id).await.unwrap();

        let state = repo.docs.lock().await.get(&id).cloned().unwrap();
        let guard = state.lock().await;
        assert_eq!(
            guard.staged_heads.as_deref(),
            Some(&guard.doc.get_heads()[..])
        );
    }

    #[tokio::test]
    async fn evicted_docs_reopen_with_the_same_heads() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "first", "saved");
                Ok(())
            })
            .await
            .unwrap();
        repo.change_doc(id, |doc| {
            put(doc, "second", "also saved");
            Ok(())
        })
        .await
        .unwrap();
        let expected = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();

        evict_when_settled(&repo, id).await;
        let loaded = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        assert_eq!(loaded, expected);
    }

    #[tokio::test]
    async fn eviction_skips_a_pending_deferred_save_then_keeps_the_edit() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "first", "saved");
                Ok(())
            })
            .await
            .unwrap();
        let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        repo.change_doc_at_deferred_ingest(id, heads, |doc| {
            put(doc, "second", "deferred");
            Ok(())
        })
        .await
        .unwrap();
        let expected = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();

        assert!(!repo.evict_doc(id).await);
        assert!(repo.docs.lock().await.get(&id).is_some());

        evict_when_settled(&repo, id).await;
        let loaded = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        assert_eq!(loaded, expected);
    }

    #[tokio::test]
    async fn pinned_docs_are_never_swept() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "value", "pinned");
                Ok(())
            })
            .await
            .unwrap();
        repo.pin_doc(id);
        repo.pin_doc(id);
        repo.sweep_idle_docs(Duration::ZERO).await;
        assert!(repo.docs.lock().await.get(&id).is_some());

        repo.unpin_doc(id);
        repo.sweep_idle_docs(Duration::ZERO).await;
        assert!(
            repo.docs.lock().await.get(&id).is_some(),
            "one of two pins released should still hold the doc"
        );

        repo.unpin_doc(id);
        timeout(Duration::from_secs(10), async {
            loop {
                repo.sweep_idle_docs(Duration::ZERO).await;
                if repo.docs.lock().await.get(&id).is_none() {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("unpinned doc should be swept");
    }

    #[tokio::test]
    async fn moon_deferred_docs_are_never_swept() {
        let (_dir, repo) = test_repo().await;
        let sending = repo
            .create_doc(|doc| {
                put(doc, "value", "before");
                Ok(())
            })
            .await
            .unwrap();
        let applying = repo
            .create_doc(|doc| {
                put(doc, "value", "before");
                Ok(())
            })
            .await
            .unwrap();

        repo.set_send_changes(false).await;
        repo.change_doc(sending, |doc| {
            put(doc, "value", "after");
            Ok(())
        })
        .await
        .unwrap();
        assert!(repo.deferred_sends.lock().await.contains(&sending));

        repo.set_apply_incoming(false).await;
        let mut remote = repo.read_doc(applying, |doc| Ok(doc.fork())).await.unwrap();
        remote.set_actor(ActorId::from([22; 16].as_slice()));
        put(&mut remote, "remote", "waiting");
        let ingested = ingest(
            &remote,
            applying.sedimentree_id(),
            &HashSet::new(),
            &HashSet::new(),
        )
        .unwrap();
        repo.core
            .store_built_batch(
                applying.sedimentree_id(),
                ingested.commits,
                ingested.fragments,
            )
            .await
            .unwrap();
        timeout(Duration::from_secs(2), async {
            while !repo.deferred_applies.lock().await.contains(&applying) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();

        repo.sweep_idle_docs(Duration::ZERO).await;
        assert!(repo.docs.lock().await.get(&sending).is_some());
        assert!(repo.docs.lock().await.get(&applying).is_some());
    }

    /// The sweep's whole policy. A count of docs is what it falls back to;
    /// where the OS reports headroom, that decides.
    #[test]
    fn low_headroom_takes_docs_the_resident_count_would_have_kept() {
        let idle = Duration::from_secs(300);
        let fresh = Duration::from_secs(1);
        let plenty = Some(4 * 1024 * 1024 * 1024);
        let scarce = Some(LOW_HEADROOM - 1);

        assert!(sweep_takes(idle, idle, 1, plenty), "past idle, always");
        assert!(!sweep_takes(fresh, idle, 1, plenty));
        assert!(sweep_takes(fresh, idle, MAX_RESIDENT_DOCS + 1, plenty));
        assert!(
            sweep_takes(fresh, idle, 1, scarce),
            "headroom overrides age"
        );
        // No limit reported (macOS, Linux): the resident ceiling is all there is.
        assert!(!sweep_takes(fresh, idle, 1, None));
        assert!(sweep_takes(fresh, idle, MAX_RESIDENT_DOCS + 1, None));

        // The memory-pressure sweep takes everything, headroom notwithstanding.
        assert!(sweep_takes(Duration::ZERO, Duration::ZERO, 1, plenty));
    }

    /// Memory pressure repeats; one sweep runs at a time.
    #[tokio::test]
    async fn a_sweep_in_flight_turns_the_next_one_away() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "value", "resident");
                Ok(())
            })
            .await
            .unwrap();
        repo.unpin_doc(id);

        let in_flight = repo.sweep_lock.lock().await;
        assert_eq!(repo.sweep_idle_docs(Duration::ZERO).await, 0);
        assert!(
            repo.docs.lock().await.get(&id).is_some(),
            "the turned-away sweep should not have touched anything"
        );
        drop(in_flight);

        timeout(Duration::from_secs(10), async {
            loop {
                repo.sweep_idle_docs(Duration::ZERO).await;
                if repo.docs.lock().await.get(&id).is_none() {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("once the lock is free the sweep should run again");
    }

    #[tokio::test]
    async fn sweep_only_takes_idle_docs_unless_over_the_resident_cap() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "value", "fresh");
                Ok(())
            })
            .await
            .unwrap();
        assert_eq!(repo.sweep_idle_docs(EVICT_IDLE).await, 0);
        assert!(repo.docs.lock().await.get(&id).is_some());

        for n in 0..MAX_RESIDENT_DOCS + 5 {
            repo.create_doc(|doc| {
                put(doc, "n", n as i64);
                Ok(())
            })
            .await
            .unwrap();
        }
        timeout(Duration::from_secs(20), async {
            loop {
                repo.sweep_idle_docs(EVICT_IDLE).await;
                if repo.docs.lock().await.len() <= MAX_RESIDENT_DOCS {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("sweep should trim residents down to the cap");
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
        repo.change_doc_at_deferred_ingest(id, heads, |doc| {
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

    /// Rebuild a doc from nothing but what is on disk, the way a fresh
    /// process would: the sedimentree, then the outbox log replayed over it.
    async fn rebuild_from_disk(repo: &Arc<Repo>, id: DocId) -> Automerge {
        let mut doc = repo.stored_doc(id).await.unwrap();
        if let Ok(bytes) = std::fs::read(repo.outbox_path(id)) {
            merge_outbox_into(&mut doc, &bytes).unwrap();
        }
        doc
    }

    /// Throw away the scheduled ingest without running it, the way a kill
    /// throws away everything the process was about to do.
    async fn abandon_pending_saves(repo: &Arc<Repo>) {
        for (_, pending) in repo.pending_saves.lock().await.drain() {
            pending.handle.abort();
        }
    }

    /// The guarantee: an editor keystroke is on disk by the time the call
    /// returns — no debounce elapsed, no flush, no clean shutdown.
    #[tokio::test]
    async fn a_keystroke_is_durable_before_the_call_returns() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "first", "saved");
                Ok(())
            })
            .await
            .unwrap();
        let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        repo.change_doc_at_deferred_ingest(id, heads, |doc| {
            put(doc, "second", "typed");
            Ok(())
        })
        .await
        .unwrap();
        let expected = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();

        // The ingest is still only scheduled — this is the window the crash
        // reports died in.
        assert!(
            !repo.pending_saves.lock().await.is_empty(),
            "the sedimentree ingest should still be pending"
        );
        abandon_pending_saves(&repo).await;

        assert_eq!(
            rebuild_from_disk(&repo, id).await.get_heads(),
            expected,
            "the keystroke should already be reconstructable from disk"
        );
    }

    /// Same guarantee across a burst long enough that the debounce fires
    /// partway through, so the log gets restarted mid-burst and later
    /// keystrokes append to a log that begins mid-history.
    #[tokio::test]
    async fn every_keystroke_in_a_burst_survives() {
        let (_dir, repo) = test_repo().await;
        let id = repo.create_doc(|_| Ok(())).await.unwrap();
        for i in 0..40i64 {
            let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
            repo.change_doc_at_deferred_ingest(id, heads, move |doc| {
                put(doc, "n", i);
                Ok(())
            })
            .await
            .unwrap();
            if i % 7 == 0 {
                tokio::time::sleep(SAVE_DEBOUNCE * 2).await;
            }
        }
        let expected = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        abandon_pending_saves(&repo).await;

        assert_eq!(
            rebuild_from_disk(&repo, id).await.get_heads(),
            expected,
            "every keystroke in the burst should be on disk"
        );
    }

    /// After an ingest the log restarts from the heads the sedimentree took,
    /// rather than losing its baseline — which would make the next keystroke
    /// rewrite the whole note instead of appending one change to it.
    #[tokio::test]
    async fn the_log_restarts_from_the_ingested_heads() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "a", "1");
                Ok(())
            })
            .await
            .unwrap();
        let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        repo.change_doc_at_deferred_ingest(id, heads, |doc| {
            put(doc, "b", "2");
            Ok(())
        })
        .await
        .unwrap();
        assert!(repo.outbox_path(id).exists(), "the keystroke is logged");

        repo.flush_pending_saves().await;
        assert!(!repo.outbox_path(id).exists(), "an ingested log is dropped");

        let now = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        let state = repo.doc_state(id).await.unwrap();
        let staged = state.lock().await.staged_heads.clone();
        assert_eq!(
            staged,
            Some(now),
            "the next keystroke should append from here, not rewrite"
        );
    }

    /// An ingest that finishes after the next keystroke must leave the log
    /// alone: the newer change is in it and nowhere else yet.
    #[tokio::test]
    async fn truncating_skips_a_log_that_moved_on() {
        let (_dir, repo) = test_repo().await;
        let id = repo
            .create_doc(|doc| {
                put(doc, "a", "1");
                Ok(())
            })
            .await
            .unwrap();
        let stale = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        repo.change_doc_at_deferred_ingest(id, stale.clone(), |doc| {
            put(doc, "b", "2");
            Ok(())
        })
        .await
        .unwrap();
        abandon_pending_saves(&repo).await;
        let expected = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();

        repo.truncate_outbox(id, &stale).await;

        assert!(
            repo.outbox_path(id).exists(),
            "the log still holds a change the sedimentree never took"
        );
        assert_eq!(rebuild_from_disk(&repo, id).await.get_heads(), expected);
    }

    /// The suspend path: a debounced edit has to be on disk before the
    /// process can be killed, and durable enough that a *fresh* repo over
    /// the same directory sees it. Reloading through `drop_doc` would not
    /// prove this — `drop_doc` flushes pending saves itself.
    #[tokio::test]
    async fn flush_pending_saves_persists_a_debounced_change() {
        let dir = tempfile::tempdir().unwrap();
        let repo = Repo::start(dir.path().to_path_buf(), "http://[".to_string(), false)
            .await
            .unwrap();
        let id = repo
            .create_doc(|doc| {
                put(doc, "first", "saved");
                Ok(())
            })
            .await
            .unwrap();
        let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        repo.change_doc_at_deferred_ingest(id, heads, |doc| {
            put(doc, "second", "deferred");
            Ok(())
        })
        .await
        .unwrap();
        let expected = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        assert!(
            !repo.pending_saves.lock().await.is_empty(),
            "the change should still be held by the save debounce"
        );

        repo.flush_pending_saves().await;
        assert!(
            repo.pending_saves.lock().await.is_empty(),
            "flush should leave nothing waiting on the debounce"
        );

        // Stand in for the process being killed: nothing else gets to run.
        drop(repo);
        let reopened = Repo::start(dir.path().to_path_buf(), "http://[".to_string(), false)
            .await
            .unwrap();
        reopened.ensure_doc(id).await.unwrap();
        let loaded = reopened
            .read_doc(id, |doc| Ok(doc.get_heads()))
            .await
            .unwrap();
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
        repo.change_doc_at_deferred_ingest(id, heads, |doc| {
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
