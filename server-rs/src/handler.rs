//! Dispatches [`WireMessage`] variants: sync traffic to the core
//! [`SyncHandler`], ephemeral traffic to the [`EphemeralHandler`] relay
//! (whose errors are non-fatal).

use std::sync::Arc;

use future_form::Sendable;
use futures::future::BoxFuture;
use sedimentree_core::{depth::CountLeadingZeroBytes, id::SedimentreeId};
use subduction_core::{
    authenticated::Authenticated,
    connection::message::SyncMessage,
    handler::{sync::SyncHandler, Handler},
    peer::id::PeerId,
    policy::open::OpenPolicy,
    remote_heads::{RemoteHeads, RemoteHeadsNotifier},
    subduction::error::{IoError, ListenError},
};
use subduction_ephemeral::{
    clock::std_clock::StdClock, handler::EphemeralHandler, policy::OpenEphemeralPolicy,
};
use sedimentree_fs_storage::FsStorage;
use subduction_websocket::tokio::{TokioSpawn, TrackedTokioSpawn};

use crate::{wire::WireMessage, Conn};

pub type ServerSyncHandler = Arc<
    SyncHandler<Sendable, FsStorage, Conn, OpenPolicy, CountLeadingZeroBytes, TrackedTokioSpawn>,
>;

pub type ServerEphemeralHandler =
    EphemeralHandler<Sendable, Conn, OpenEphemeralPolicy, StdClock, TokioSpawn>;

type ServerListenError = ListenError<Sendable, FsStorage, Conn, WireMessage>;

pub struct ServerHandler {
    sync: ServerSyncHandler,
    ephemeral: ServerEphemeralHandler,
}

impl ServerHandler {
    pub const fn new(sync: ServerSyncHandler, ephemeral: ServerEphemeralHandler) -> Self {
        Self { sync, ephemeral }
    }
}

impl core::fmt::Debug for ServerHandler {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("ServerHandler").finish_non_exhaustive()
    }
}

impl RemoteHeadsNotifier for ServerHandler {
    fn notify_remote_heads(&self, id: SedimentreeId, peer: PeerId, heads: RemoteHeads) {
        RemoteHeadsNotifier::notify_remote_heads(self.sync.as_ref(), id, peer, heads);
    }
}

impl Handler<Sendable, Conn> for ServerHandler {
    type Message = WireMessage;
    type HandlerError = ServerListenError;

    fn handle<'a>(
        &'a self,
        conn: &'a Authenticated<Conn, Sendable>,
        message: WireMessage,
    ) -> BoxFuture<'a, Result<(), Self::HandlerError>> {
        Box::pin(async move {
            match message {
                WireMessage::Sync(sync_msg) => {
                    Handler::<Sendable, Conn>::handle(self.sync.as_ref(), conn, *sync_msg)
                        .await
                        .map_err(convert_sync_listen_error)
                }
                WireMessage::Ephemeral(eph_msg) => {
                    if let Err(e) =
                        Handler::<Sendable, Conn>::handle(&self.ephemeral, conn, eph_msg).await
                    {
                        tracing::error!(error = %e, "ephemeral handler error (non-fatal)");
                    }
                    Ok(())
                }
            }
        })
    }

    fn on_peer_disconnect(&self, peer: PeerId) -> BoxFuture<'_, ()> {
        Box::pin(async move {
            Handler::<Sendable, Conn>::on_peer_disconnect(self.sync.as_ref(), peer).await;
            Handler::<Sendable, Conn>::on_peer_disconnect(&self.ephemeral, peer).await;
        })
    }
}

fn convert_sync_listen_error(
    err: ListenError<Sendable, FsStorage, Conn, SyncMessage>,
) -> ServerListenError {
    match err {
        ListenError::IoError(io_err) => ListenError::IoError(match io_err {
            IoError::Storage(e) => IoError::Storage(e),
            IoError::ConnSend(e) => IoError::ConnSend(e),
            IoError::ConnRecv(e) => IoError::ConnRecv(e),
            IoError::ConnCall(e) => IoError::ConnCall(e),
            IoError::BlobMismatch(e) => IoError::BlobMismatch(e),
        }),
        ListenError::TrySendError => ListenError::TrySendError,
    }
}
