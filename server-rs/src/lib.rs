uniffi::setup_scaffolding!();

mod peers;

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use sedimentree_fs_storage::FsStorage;
use swampland::{key, Config, Server};

type FsServer = Server<FsStorage>;

struct Running {
    runtime: tokio::runtime::Runtime,
    server: FsServer,
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

fn locked() -> std::sync::MutexGuard<'static, Option<Running>> {
    SERVER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Starts the sync server on 127.0.0.1. `port` 0 binds an ephemeral port.
/// With `enable_iroh` it also binds an iroh endpoint and redials saved iroh
/// peers; without it nothing reaches for a relay. Returns the bound port.
#[uniffi::export]
pub fn server_start(data_dir: String, port: u16, enable_iroh: bool) -> Result<u16, ServerError> {
    let mut guard = locked();
    if guard.is_some() {
        return Err(ServerError::AlreadyRunning);
    }

    let data_dir = PathBuf::from(data_dir);
    std::fs::create_dir_all(&data_dir).map_err(fail)?;
    let seed = key::load_or_create_seed(&data_dir.join("server.key")).map_err(fail)?;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("patchwork-server")
        .build()
        .map_err(fail)?;

    // The same on-disk sedimentree the app's core uses, so a doc synced
    // through the server and a doc opened in the app are one copy, not two.
    let storage = FsStorage::new(data_dir.join("sedimentree")).map_err(fail)?;
    let config = Config {
        bind: ([127, 0, 0, 1], port).into(),
        iroh: enable_iroh,
        ..Config::default()
    };
    let server = runtime
        .block_on(Server::start(config, storage, &seed))
        .map_err(fail)?;

    let bound_port = server.port();
    let peer_id = server.peer_id().to_string();
    let iroh_node_id = server.iroh_node_id().map(|id| id.to_string());

    for saved in peers::load(&data_dir) {
        if let Ok(public_key) = saved.parse::<iroh::PublicKey>() {
            spawn_dial(&runtime, &server, public_key);
        }
    }

    *guard = Some(Running {
        runtime,
        server,
        data_dir,
        port: bound_port,
        peer_id,
        iroh_node_id,
    });
    Ok(bound_port)
}

fn spawn_dial(runtime: &tokio::runtime::Runtime, server: &FsServer, key: iroh::PublicKey) {
    let server = server.clone();
    runtime.spawn(async move {
        if let Err(e) = server.connect_iroh_peer(key).await {
            tracing::warn!(error = %e, "could not reach iroh peer");
        }
    });
}

#[uniffi::export]
pub fn server_stop() {
    if let Some(running) = locked().take() {
        running.server.shutdown();
        running.runtime.shutdown_timeout(Duration::from_secs(3));
    }
}

#[uniffi::export]
pub fn server_port() -> Option<u16> {
    locked().as_ref().map(|running| running.port)
}

#[uniffi::export]
pub fn server_peer_id() -> Option<String> {
    locked().as_ref().map(|running| running.peer_id.clone())
}

/// The iroh node id friends dial to sync with this server.
#[uniffi::export]
pub fn server_iroh_node_id() -> Option<String> {
    locked().as_ref().and_then(|r| r.iroh_node_id.clone())
}

/// Saved friend node ids.
#[uniffi::export]
pub fn server_iroh_peers() -> Vec<String> {
    locked()
        .as_ref()
        .map(|running| peers::load(&running.data_dir))
        .unwrap_or_default()
}

/// Save a friend's iroh node id and dial them now.
#[uniffi::export]
pub fn server_add_iroh_peer(node_id: String) -> Result<(), ServerError> {
    let public_key: iroh::PublicKey = node_id.parse().map_err(fail)?;
    let guard = locked();
    let running = guard.as_ref().ok_or(ServerError::NotRunning)?;

    peers::add(&running.data_dir, node_id);
    spawn_dial(&running.runtime, &running.server, public_key);
    Ok(())
}
