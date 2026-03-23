use std::sync::Arc;

use axum::{
    body::Bytes,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use tracing::{info, error};

use crate::AppState;
use crate::auth;
use crate::helper::{HelperCommand, ContainerDefinition};

fn get_auth_header(headers: &HeaderMap) -> Option<String> {
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

/// POST /api/v1/deploy — Deploy a container.
pub async fn deploy(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    let auth_header = match get_auth_header(&headers) {
        Some(h) => h,
        None => return (StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "missing Authorization header"}))),
    };

    let claims = match auth::validate_token(&state, &auth_header).await {
        Ok(c) => c,
        Err((status, msg)) => {
            error!(error = %msg, "auth failed");
            return (status, Json(serde_json::json!({"error": msg})));
        }
    };

    let def: ContainerDefinition = match serde_json::from_slice(&body) {
        Ok(d) => d,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": format!("invalid request body: {}", e)}))),
    };

    info!(user = %claims.sub, container = %def.name, "deploy request");

    match state.helper.send(HelperCommand::Deploy(def)).await {
        Ok(resp) if resp.success => {
            (StatusCode::OK, Json(helper_ok_json(&resp)))
        }
        Ok(resp) => {
            (StatusCode::UNPROCESSABLE_ENTITY, Json(serde_json::json!({"error": resp.message})))
        }
        Err(e) => {
            error!(error = %e, "helper communication error");
            (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({"error": "internal error"})))
        }
    }
}

/// DELETE /api/v1/teardown/:name — Tear down a container.
pub async fn teardown(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let auth_header = match get_auth_header(&headers) {
        Some(h) => h,
        None => return (StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "missing Authorization header"}))),
    };

    let claims = match auth::validate_token(&state, &auth_header).await {
        Ok(c) => c,
        Err((status, msg)) => {
            error!(error = %msg, "auth failed");
            return (status, Json(serde_json::json!({"error": msg})));
        }
    };

    info!(user = %claims.sub, container = %name, "teardown request");

    match state.helper.send(HelperCommand::Teardown { name: name.clone() }).await {
        Ok(resp) if resp.success => {
            (StatusCode::OK, Json(helper_ok_json(&resp)))
        }
        Ok(resp) => {
            (StatusCode::UNPROCESSABLE_ENTITY, Json(serde_json::json!({"error": resp.message})))
        }
        Err(e) => {
            error!(error = %e, "helper communication error");
            (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({"error": "internal error"})))
        }
    }
}

/// GET /api/v1/status — Check deployd-helper status.
pub async fn status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let auth_header = match get_auth_header(&headers) {
        Some(h) => h,
        None => return (StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "missing Authorization header"}))),
    };

    if let Err((status, msg)) = auth::validate_token(&state, &auth_header).await {
        error!(error = %msg, "auth failed");
        return (status, Json(serde_json::json!({"error": msg})));
    }

    match state.helper.send(HelperCommand::Status).await {
        Ok(resp) => {
            let status_code = if resp.success { StatusCode::OK } else { StatusCode::SERVICE_UNAVAILABLE };
            (status_code, Json(helper_ok_json(&resp)))
        }
        Err(e) => {
            error!(error = %e, "helper communication error");
            (StatusCode::SERVICE_UNAVAILABLE, Json(serde_json::json!({"error": "helper unreachable"})))
        }
    }
}

/// Build a JSON response from a successful helper response, including data if present.
fn helper_ok_json(resp: &crate::helper::HelperResponse) -> serde_json::Value {
    let mut obj = serde_json::json!({"message": resp.message});
    if let Some(ref data) = resp.data {
        obj["data"] = data.clone();
    }
    obj
}

/// GET /healthz — Unauthenticated health check for load balancers/probes.
pub async fn healthz() -> impl IntoResponse {
    (StatusCode::OK, Json(serde_json::json!({"status": "ok"})))
}
