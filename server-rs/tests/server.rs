use std::{net::TcpStream, sync::Mutex};

use async_tungstenite::tungstenite::http::Uri;
use subduction_core::handshake::audience::Audience;
use subduction_crypto::signer::memory::MemorySigner;
use subduction_websocket::tokio::client::TokioWebSocketClient;

static TEST_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn starts_accepts_stops_with_stable_peer_id() {
    let _guard = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let dir = std::env::temp_dir().join(format!("patchwork-server-test-{}", std::process::id()));
    let data_dir = dir.to_string_lossy().into_owned();

    let port = patchwork_server::server_start(data_dir.clone(), 0).unwrap();
    assert_ne!(port, 0);
    let peer_id = patchwork_server::server_peer_id().unwrap();
    assert_eq!(patchwork_server::server_port(), Some(port));
    // The code friends dial is the identity their handshake addresses.
    assert_eq!(
        patchwork_server::server_iroh_node_id(),
        Some(peer_id.clone())
    );

    TcpStream::connect(("127.0.0.1", port)).expect("server should accept connections");

    assert!(matches!(
        patchwork_server::server_start(data_dir.clone(), 0),
        Err(patchwork_server::ServerError::AlreadyRunning)
    ));

    patchwork_server::server_stop();
    assert_eq!(patchwork_server::server_port(), None);

    let port2 = patchwork_server::server_start(data_dir, 0).unwrap();
    let peer_id2 = patchwork_server::server_peer_id().unwrap();
    patchwork_server::server_stop();

    assert_eq!(peer_id, peer_id2);
    assert_ne!(port2, 0);

    std::fs::remove_dir_all(dir).ok();
}

#[test]
fn accepts_subduction_websocket_handshake() {
    let _guard = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let dir = std::env::temp_dir().join(format!(
        "patchwork-server-handshake-test-{}",
        std::process::id()
    ));
    let data_dir = dir.to_string_lossy().into_owned();

    let port = patchwork_server::server_start(data_dir, 0).unwrap();
    let server_peer_id = patchwork_server::server_peer_id().unwrap();
    let service_name = format!("127.0.0.1:{port}");
    let uri: Uri = format!("ws://{service_name}").parse().unwrap();
    let signer = MemorySigner::from_bytes(&[7u8; 32]);

    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let (authenticated, listener, sender, keepalive) =
            TokioWebSocketClient::new(uri, signer, Audience::discover(service_name.as_bytes()))
                .await
                .unwrap();
        let listener_handle = tokio::spawn(async move {
            let _ = listener.await;
        });
        let sender_handle = tokio::spawn(async move {
            let _ = sender.await;
        });
        let keepalive_handle = tokio::spawn(async move {
            let _ = keepalive.await;
        });

        assert_eq!(authenticated.peer_id().to_string(), server_peer_id);

        listener_handle.abort();
        sender_handle.abort();
        keepalive_handle.abort();
    });
    patchwork_server::server_stop();
    std::fs::remove_dir_all(dir).ok();
}
