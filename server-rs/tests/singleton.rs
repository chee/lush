use std::net::TcpStream;
use std::sync::Mutex;

use patchwork_server::{
    server_iroh_node_id, server_peer_id, server_port, server_start, server_stop, ServerError,
};

static TEST_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn starts_accepts_stops_with_stable_peer_id() {
    let _guard = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let data_dir = dir.path().to_string_lossy().into_owned();

    let port = server_start(data_dir.clone(), 0, true).unwrap();
    assert_ne!(port, 0);
    let peer_id = server_peer_id().unwrap();
    assert_eq!(server_port(), Some(port));
    // The code friends dial is the identity their handshake addresses.
    assert_eq!(server_iroh_node_id(), Some(peer_id.clone()));

    TcpStream::connect(("127.0.0.1", port)).expect("server should accept connections");

    assert!(matches!(
        server_start(data_dir.clone(), 0, true),
        Err(ServerError::AlreadyRunning)
    ));

    server_stop();
    assert_eq!(server_port(), None);

    let port2 = server_start(data_dir, 0, false).unwrap();
    assert_ne!(port2, 0);
    assert_eq!(server_peer_id(), Some(peer_id));
    server_stop();
}

#[test]
fn adding_a_peer_while_stopped_is_an_error() {
    let _guard = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(matches!(
        patchwork_server::server_add_iroh_peer(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into()
        ),
        Err(ServerError::NotRunning)
    ));
}
