use axum::http::StatusCode;
use jsonwebtoken::{decode, Algorithm, DecodingKey, Validation};
use serde::Deserialize;
use tokio::sync::RwLock;
use tracing::info;

use crate::AppState;

/// Cached JWKS keys from the OIDC provider.
pub struct JwksCache {
    url: String,
    keys: RwLock<Option<jsonwebtoken::jwk::JwkSet>>,
}

impl JwksCache {
    pub fn new(url: String) -> Self {
        Self {
            url,
            keys: RwLock::new(None),
        }
    }

    /// Fetch JWKS from the OIDC provider, caching the result.
    pub async fn get_keys(&self) -> Result<jsonwebtoken::jwk::JwkSet, String> {
        // Return cached if available
        {
            let cached = self.keys.read().await;
            if let Some(ref keys) = *cached {
                return Ok(keys.clone());
            }
        }

        self.refresh().await
    }

    /// Invalidate the cache and re-fetch from the OIDC provider.
    pub async fn refresh(&self) -> Result<jsonwebtoken::jwk::JwkSet, String> {
        let resp = reqwest::get(&self.url)
            .await
            .map_err(|e| format!("JWKS fetch failed: {}", e))?;
        let jwks: jsonwebtoken::jwk::JwkSet = resp
            .json()
            .await
            .map_err(|e| format!("JWKS parse failed: {}", e))?;

        let mut cached = self.keys.write().await;
        *cached = Some(jwks.clone());
        info!("JWKS cache refreshed");
        Ok(jwks)
    }
}

/// JWT claims we validate.
#[derive(Debug, Deserialize)]
pub struct Claims {
    pub sub: String,
    #[serde(default)]
    pub groups: Vec<String>,
}

/// Extract and validate a Bearer token from the Authorization header.
pub async fn validate_token(
    state: &AppState,
    auth_header: &str,
) -> Result<Claims, (StatusCode, String)> {
    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or((StatusCode::UNAUTHORIZED, "missing Bearer prefix".into()))?;

    let jwks = state
        .jwks
        .get_keys()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    // Decode header to find the key ID
    let header = jsonwebtoken::decode_header(token)
        .map_err(|e| (StatusCode::UNAUTHORIZED, format!("invalid token header: {}", e)))?;

    let kid = header
        .kid
        .ok_or((StatusCode::UNAUTHORIZED, "token missing kid".into()))?;

    // Try cached keys first; on miss, refresh once (handles key rotation)
    let mut keyset = jwks;
    if keyset.find(&kid).is_none() {
        keyset = state
            .jwks
            .refresh()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    }

    let jwk = keyset.find(&kid).ok_or_else(|| {
        (StatusCode::UNAUTHORIZED, format!("unknown key id: {}", kid))
    })?;

    let key = DecodingKey::from_jwk(jwk)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("JWK decode error: {}", e)))?;

    let mut validation = Validation::new(Algorithm::RS256);
    validation.set_issuer(&[&state.config.oidc_issuer]);
    // Keycloak doesn't always include the client_id in aud for bearer-only clients,
    // so we disable strict audience validation.
    validation.validate_aud = false;

    let token_data = decode::<Claims>(token, &key, &validation)
        .map_err(|e| (StatusCode::UNAUTHORIZED, format!("token validation failed: {}", e)))?;

    let claims = token_data.claims;

    // Check group membership
    if !claims.groups.iter().any(|g| g == &state.config.required_group) {
        return Err((
            StatusCode::FORBIDDEN,
            format!("missing required group: {}", state.config.required_group),
        ));
    }

    Ok(claims)
}
