//! Unified transport so one Subduction instance carries both the local
//! WebSocket peers (the page, pushwork) and iroh QUIC peers (friends).

use future_form::Sendable;
use futures::future::BoxFuture;
use subduction_core::transport::Transport;
use subduction_iroh::transport::IrohTransport;
use subduction_websocket::tokio::unified::UnifiedWebSocket;

#[derive(Debug, Clone)]
pub enum UnifiedTransport {
    WebSocket(UnifiedWebSocket),
    Iroh(IrohTransport),
}

#[derive(Debug, Clone, Copy, thiserror::Error)]
pub enum TransportSendError {
    #[error(transparent)]
    WebSocket(#[from] subduction_websocket::error::SendError),
    #[error(transparent)]
    Iroh(#[from] subduction_iroh::error::SendError),
}

#[derive(Debug, Clone, Copy, thiserror::Error)]
pub enum TransportRecvError {
    #[error(transparent)]
    WebSocket(#[from] subduction_websocket::error::RecvError),
    #[error(transparent)]
    Iroh(#[from] subduction_iroh::error::RecvError),
}

#[derive(Debug, Clone, Copy, thiserror::Error)]
pub enum TransportDisconnectionError {
    #[error(transparent)]
    WebSocket(#[from] subduction_websocket::error::DisconnectionError),
    #[error(transparent)]
    Iroh(#[from] subduction_iroh::error::DisconnectionError),
}

impl Transport<Sendable> for UnifiedTransport {
    type SendError = TransportSendError;
    type RecvError = TransportRecvError;
    type DisconnectionError = TransportDisconnectionError;

    fn send_bytes(&self, bytes: &[u8]) -> BoxFuture<'_, Result<(), Self::SendError>> {
        match self {
            Self::WebSocket(ws) => {
                let fut = Transport::<Sendable>::send_bytes(ws, bytes);
                Box::pin(async move { fut.await.map_err(Into::into) })
            }
            Self::Iroh(iroh) => {
                let fut = Transport::<Sendable>::send_bytes(iroh, bytes);
                Box::pin(async move { fut.await.map_err(Into::into) })
            }
        }
    }

    fn recv_bytes(&self) -> BoxFuture<'_, Result<Vec<u8>, Self::RecvError>> {
        match self {
            Self::WebSocket(ws) => Box::pin(async {
                Transport::<Sendable>::recv_bytes(ws)
                    .await
                    .map_err(Into::into)
            }),
            Self::Iroh(iroh) => Box::pin(async {
                Transport::<Sendable>::recv_bytes(iroh)
                    .await
                    .map_err(Into::into)
            }),
        }
    }

    fn disconnect(&self) -> BoxFuture<'_, Result<(), Self::DisconnectionError>> {
        match self {
            Self::WebSocket(ws) => Box::pin(async {
                Transport::<Sendable>::disconnect(ws)
                    .await
                    .map_err(Into::into)
            }),
            Self::Iroh(iroh) => Box::pin(async {
                Transport::<Sendable>::disconnect(iroh)
                    .await
                    .map_err(Into::into)
            }),
        }
    }
}

impl PartialEq for UnifiedTransport {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::WebSocket(a), Self::WebSocket(b)) => a == b,
            (Self::Iroh(a), Self::Iroh(b)) => a == b,
            _ => false,
        }
    }
}
