/// Configuration from environment variables.
pub struct Config {
    /// vsock port for the deployd-helper on the host (CID 2).
    pub helper_vsock_port: u32,
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
            helper_vsock_port: require_env("DEPLOYD_HELPER_VSOCK_PORT")
                .parse()
                .unwrap_or_else(|e| panic!("DEPLOYD_HELPER_VSOCK_PORT: {}", e)),
            capability_token: read_secret_file("DEPLOYD_CAPABILITY_TOKEN_FILE"),
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

fn read_secret_file(key: &str) -> String {
    let path = require_env(key);
    std::fs::read_to_string(&path)
        .map(|s| s.trim_end().to_string())
        .unwrap_or_else(|e| panic!("{}: {}", path, e))
}
