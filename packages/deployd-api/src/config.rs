/// Configuration from environment variables.
pub struct Config {
    /// Path to the deployd-helper Unix socket on the host (via virtiofs mount).
    pub helper_socket_path: String,
    /// Capability token for authenticating with deployd-helper.
    pub capability_token: String,
    /// OIDC issuer URL (Keycloak realm endpoint).
    pub oidc_issuer: String,
    /// OIDC JWKS URL for token validation.
    pub oidc_jwks_url: String,
    /// Required group claim for authorization.
    pub required_group: String,
}

impl Config {
    pub fn from_env() -> Self {
        let oidc_issuer = require_env("DEPLOYD_OIDC_ISSUER");
        let oidc_jwks_url = std::env::var("DEPLOYD_OIDC_JWKS_URL")
            .unwrap_or_else(|_| format!("{}/protocol/openid-connect/certs", oidc_issuer));

        Self {
            helper_socket_path: require_env("DEPLOYD_HELPER_SOCKET"),
            capability_token: require_env("DEPLOYD_CAPABILITY_TOKEN"),
            oidc_issuer,
            oidc_jwks_url,
            required_group: std::env::var("DEPLOYD_REQUIRED_GROUP")
                .unwrap_or_else(|_| "deploy".to_string()),
        }
    }
}

fn require_env(name: &str) -> String {
    std::env::var(name)
        .unwrap_or_else(|_| panic!("{} must be set", name))
}
