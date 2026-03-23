use std::net::SocketAddr;
use std::sync::Arc;

use axum::{
    Router,
    routing::{get, post, delete},
};
use tower_http::trace::TraceLayer;
use tracing::info;

mod auth;
mod config;
mod helper;
mod routes;

use config::Config;
use helper::HelperClient;

/// Shared application state.
pub struct AppState {
    pub config: Config,
    pub helper: HelperClient,
    pub jwks: auth::JwksCache,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .json()
        .with_target(false)
        .init();

    let config = Config::from_env();
    let helper = HelperClient::new(
        config.helper_socket_path.clone(),
        config.capability_token.clone(),
    );
    let jwks = auth::JwksCache::new(config.oidc_jwks_url.clone());

    let state = Arc::new(AppState {
        config,
        helper,
        jwks,
    });

    let app = Router::new()
        .route("/api/v1/deploy", post(routes::deploy))
        .route("/api/v1/teardown/{name}", delete(routes::teardown))
        .route("/api/v1/status", get(routes::status))
        .route("/healthz", get(routes::healthz))
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr: SocketAddr = ([0, 0, 0, 0], 8443).into();
    info!(%addr, "deployd-api starting");

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("failed to bind");

    axum::serve(listener, app)
        .await
        .expect("server error");
}
