uniffi::setup_scaffolding!();

mod handler;
mod key;
mod transport;
mod wire;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_tungstenite::tungstenite::{handshake::server::NoCallback, protocol::WebSocketConfig};
use future_form::Sendable;
use iroh::{endpoint::presets, EndpointAddr};
use sedimentree_core::depth::CountLeadingZeroBytes;
use subduction_core::{
    handshake::{
        self,
        audience::{Audience, DiscoveryId},
    },
    nonce_cache::NonceCache,
    peer::id::PeerId,
    policy::open::OpenPolicy,
    subduction::{builder::SubductionBuilder, Subduction},
    timeout::call::CallTimeout,
    timestamp::TimestampSeconds,
    transport::message::MessageTransport,
};
use subduction_crypto::signer::memory::MemorySigner;
use subduction_ephemeral::{
    clock::std_clock::StdClock, config::EphemeralConfig, handler::EphemeralHandler,
    policy::OpenEphemeralPolicy,
};
use sedimentree_fs_storage::FsStorage;
use subduction_websocket::{
    handshake::WebSocketHandshake,
    sleep::TokioSleeper,
    timeout::FuturesTimerTimeout,
    tokio::{unified::UnifiedWebSocket, TokioSpawn, TrackedTokioSpawn},
    websocket::{KeepAlive, WebSocket},
    DEFAULT_MAX_MESSAGE_SIZE,
};
use tokio::net::TcpListener;
use tokio_util::{sync::CancellationToken, task::TaskTracker};

use handler::ServerHandler;
use transport::UnifiedTransport;

const HANDSHAKE_MAX_DRIFT: Duration = Duration::from_secs(600);

pub(crate) type Conn = MessageTransport<UnifiedTransport>;
type Node = Arc<
    Subduction<
        'static,
        Sendable,
        FsStorage,
        Conn,
        ServerHandler,
        OpenPolicy,
        MemorySigner,
        FuturesTimerTimeout,
        TrackedTokioSpawn,
        CountLeadingZeroBytes,
    >,
>;

struct Running {
    runtime: tokio::runtime::Runtime,
    node: Node,
    endpoint: Option<iroh::Endpoint>,
    signer: MemorySigner,
    cancel: CancellationToken,
    data_dir: PathBuf,
    port: u16,
    peer_id: String,
    iroh_node_id: Option<String>,
}

static SERVER: Mutex<Option<Running>> = Mutex::new(None);

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum ServerError {
    #[error("server already running")]
    AlreadyRunning,
    #[error("server not running")]
    NotRunning,
    #[error("{0}")]
    Failed(String),
}

fn fail(error: impl std::fmt::Display) -> ServerError {
    ServerError::Failed(error.to_string())
}

/// Starts the sync server on 127.0.0.1. `port` 0 binds an ephemeral port.
/// Also binds an iroh endpoint and redials saved iroh peers.
/// Returns the actually-bound websocket port.
#[uniffi::export]
pub fn server_start(data_dir: String, port: u16) -> Result<u16, ServerError> {
    let mut guard = SERVER.lock().unwrap();
    if guard.is_some() {
        return Err(ServerError::AlreadyRunning);
    }

    let data_dir = PathBuf::from(data_dir);
    std::fs::create_dir_all(&data_dir).map_err(fail)?;
    let seed = key::load_or_create_seed(&data_dir.join("server.key")).map_err(fail)?;
    let signer = MemorySigner::from_bytes(&seed);
    let peer_id = PeerId::from(signer.verifying_key());

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("subduction-server")
        .build()
        .map_err(fail)?;

    let cancel = CancellationToken::new();
    let (bound_port, node, endpoint) = runtime.block_on(start_node(
        &data_dir,
        port,
        &seed,
        signer.clone(),
        peer_id,
        cancel.clone(),
    ))?;
    let iroh_node_id = endpoint
        .as_ref()
        .map(|endpoint| endpoint.addr().id.to_string());

    if let Some(endpoint) = &endpoint {
        for saved in load_peers(&data_dir) {
            if let Ok(public_key) = saved.parse::<iroh::PublicKey>() {
                let endpoint = endpoint.clone();
                let node = node.clone();
                let signer = signer.clone();
                runtime.spawn(dial_iroh_peer(endpoint, node, signer, public_key));
            }
        }
    }

    *guard = Some(Running {
        runtime,
        node,
        endpoint,
        signer,
        cancel,
        data_dir,
        port: bound_port,
        peer_id: peer_id.to_string(),
        iroh_node_id,
    });
    Ok(bound_port)
}

async fn start_node(
    data_dir: &Path,
    requested_port: u16,
    seed: &[u8; 32],
    signer: MemorySigner,
    peer_id: PeerId,
    cancel: CancellationToken,
) -> Result<(u16, Node, Option<iroh::Endpoint>), ServerError> {
    let address: SocketAddr = ([127, 0, 0, 1], requested_port).into();
    let listener = TcpListener::bind(address).await.map_err(fail)?;
    let bound_port = listener.local_addr().map_err(fail)?.port();
    // automerge-repo's subduction client uses the URL host as the handshake
    // audience, so the discovery id must be the exact host:port clients dial.
    let service_name = format!("127.0.0.1:{bound_port}");

    // The same on-disk sedimentree the core uses, so a doc synced through the
    // server and a doc opened in the app are one copy, not two.
    let storage = FsStorage::new(data_dir.join("sedimentree")).map_err(fail)?;
    let tasks = TaskTracker::new();
    let spawner = TrackedTokioSpawn::new(tasks.clone());
    let (node, listener_fut, manager_fut, ()) = SubductionBuilder::new()
        .signer(signer.clone())
        .storage(storage, Arc::new(OpenPolicy))
        .spawner(spawner)
        .timer(FuturesTimerTimeout)
        .nonce_cache(NonceCache::default())
        .depth_metric(CountLeadingZeroBytes)
        .discovery_id(DiscoveryId::new(service_name.as_bytes()))
        .build_composed::<Sendable, Conn, _, _>(|sync_handler| {
            let (ephemeral, ephemeral_rx) = EphemeralHandler::new(
                sync_handler.connections(),
                OpenEphemeralPolicy,
                EphemeralConfig::default(),
                StdClock,
                TokioSpawn,
            );
            // The server only relays ephemeral traffic; drain the events.
            tokio::spawn(async move { while ephemeral_rx.recv().await.is_ok() {} });
            (Arc::new(ServerHandler::new(sync_handler, ephemeral)), ())
        });
    tokio::spawn(async move {
        let _ = manager_fut.await;
    });
    tokio::spawn(async move {
        let _ = listener_fut.await;
    });

    let discovery_audience = node.discovery_id().map(Audience::discover_id);

    {
        let node = node.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    () = cancel.cancelled() => break,
                    accepted = listener.accept() => {
                        let Ok((tcp, _addr)) = accepted else { continue };
                        tokio::spawn(handle_websocket(
                            tcp, node.clone(), peer_id, discovery_audience,
                        ));
                    }
                }
            }
        });
    }

    // The same key subduction signs with, so the iroh node id friends dial is
    // also the peer id their handshake addresses, and it survives a restart.
    let endpoint = iroh::Endpoint::builder(presets::N0)
        .secret_key(iroh::SecretKey::from_bytes(seed))
        .alpns(vec![subduction_iroh::ALPN.to_vec()])
        .bind()
        .await;

    let Ok(endpoint) = endpoint else {
        return Ok((bound_port, node, None));
    };

    {
        let node = node.clone();
        let endpoint = endpoint.clone();
        let signer = signer.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move {
            let nonce_cache = NonceCache::default();
            loop {
                tokio::select! {
                    () = cancel.cancelled() => break,
                    result = subduction_iroh::server::accept_one(
                        &endpoint,
                        &signer,
                        &nonce_cache,
                        peer_id,
                        discovery_audience,
                        HANDSHAKE_MAX_DRIFT,
                    ) => {
                        let Ok(accepted) = result else { continue };
                        let remote = accepted.authenticated.peer_id();
                        tokio::spawn(accepted.listener_task);
                        tokio::spawn(accepted.sender_task);
                        let auth = accepted
                            .authenticated
                            .map(|c| MessageTransport::new(UnifiedTransport::Iroh(c)));
                        if node.add_connection(auth).await.is_ok() {
                            node.full_sync_with_peer(&remote, true, CallTimeout::Default).await;
                        }
                    }
                }
            }
        });
    }

    Ok((bound_port, node, Some(endpoint)))
}

async fn handle_websocket(
    tcp: tokio::net::TcpStream,
    node: Node,
    server_peer_id: PeerId,
    discovery_audience: Option<Audience>,
) {
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
            (
                MessageTransport::new(UnifiedTransport::WebSocket(UnifiedWebSocket::Accepted(ws))),
                (),
            )
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
        return;
    };
    let _ = node.add_connection(authenticated).await;
}

async fn dial_iroh_peer(
    endpoint: iroh::Endpoint,
    node: Node,
    signer: MemorySigner,
    public_key: iroh::PublicKey,
) {
    // A node id is an ed25519 public key and so is a peer id, so the code we
    // dialed is who we expect to answer. Every responder accepts its own.
    let audience = Audience::known(PeerId::new(*public_key.as_bytes()));
    let addr = EndpointAddr::new(public_key);
    let Ok(result) = subduction_iroh::client::connect(&endpoint, addr, &signer, audience).await
    else {
        return;
    };
    tokio::spawn(result.listener_task);
    tokio::spawn(result.sender_task);
    let remote = result.authenticated.peer_id();
    let auth = result
        .authenticated
        .map(|c| MessageTransport::new(UnifiedTransport::Iroh(c)));
    if node.add_connection(auth).await.is_ok() {
        node.full_sync_with_peer(&remote, true, CallTimeout::Default)
            .await;
    }
}

fn peers_path(data_dir: &Path) -> PathBuf {
    data_dir.join("peers.json")
}

fn load_peers(data_dir: &Path) -> Vec<String> {
    std::fs::read(peers_path(data_dir))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn save_peers(data_dir: &Path, peers: &[String]) {
    if let Ok(bytes) = serde_json::to_vec_pretty(peers) {
        let _ = std::fs::write(peers_path(data_dir), bytes);
    }
}

#[uniffi::export]
pub fn server_stop() {
    if let Some(running) = SERVER.lock().unwrap().take() {
        running.cancel.cancel();
        running.node.shutdown();
        running.runtime.shutdown_timeout(Duration::from_secs(3));
    }
}

#[uniffi::export]
pub fn server_port() -> Option<u16> {
    SERVER.lock().unwrap().as_ref().map(|running| running.port)
}

#[uniffi::export]
pub fn server_peer_id() -> Option<String> {
    SERVER
        .lock()
        .unwrap()
        .as_ref()
        .map(|running| running.peer_id.clone())
}

/// The iroh node id friends dial to sync with this server.
#[uniffi::export]
pub fn server_iroh_node_id() -> Option<String> {
    SERVER
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|running| running.iroh_node_id.clone())
}

/// Saved friend node ids.
#[uniffi::export]
pub fn server_iroh_peers() -> Vec<String> {
    SERVER
        .lock()
        .unwrap()
        .as_ref()
        .map(|running| load_peers(&running.data_dir))
        .unwrap_or_default()
}

/// Save a friend's iroh node id and dial them now.
#[uniffi::export]
pub fn server_add_iroh_peer(node_id: String) -> Result<(), ServerError> {
    let public_key: iroh::PublicKey = node_id.parse().map_err(fail)?;
    let guard = SERVER.lock().unwrap();
    let running = guard.as_ref().ok_or(ServerError::NotRunning)?;

    let mut peers = load_peers(&running.data_dir);
    if !peers.contains(&node_id) {
        peers.push(node_id);
        save_peers(&running.data_dir, &peers);
    }

    if let Some(endpoint) = &running.endpoint {
        running.runtime.spawn(dial_iroh_peer(
            endpoint.clone(),
            running.node.clone(),
            running.signer.clone(),
            public_key,
        ));
    }
    Ok(())
}
