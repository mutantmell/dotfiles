use serde::Deserialize;

/// Runtime configuration loaded from environment variables or config file.
/// All paths are set by the NixOS module via environment variables.
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// Unix socket path cloud-hypervisor proxies guest vsock connections to.
    pub vsock_host_socket: String,
    pub capability_token: String,
    pub registry_allowlist: Vec<String>,
    pub hostname_allowlist: Vec<String>,
    pub port_range_min: u16,
    pub port_range_max: u16,
    pub audit_log_path: String,
    pub bridge_name: String,
    pub caddy_admin_url: String,
    pub caddy_server_name: String,
    /// containerd runtime class name (e.g. "io.containerd.kata.v2" or "io.containerd.runc.v2").
    pub runtime_class: String,
    /// Path to nerdctl, embedded in generated systemd unit files (not called directly).
    pub nerdctl_path: String,
    /// Path to the deployd-exec privileged wrapper script (invoked via sudo).
    pub deployd_exec_path: String,
}

impl Config {
    /// Load configuration from environment variables.
    pub fn from_env() -> Result<Self, String> {
        Ok(Self {
            vsock_host_socket: env_required("DEPLOYD_VSOCK_HOST_SOCKET")?,
            capability_token: read_secret_file("DEPLOYD_CAPABILITY_TOKEN_FILE")?,
            registry_allowlist: env_list("DEPLOYD_REGISTRY_ALLOWLIST"),
            hostname_allowlist: env_list("DEPLOYD_HOSTNAME_ALLOWLIST"),
            port_range_min: env_or("DEPLOYD_PORT_RANGE_MIN", "1024")
                .parse()
                .map_err(|e| format!("DEPLOYD_PORT_RANGE_MIN: {}", e))?,
            port_range_max: env_or("DEPLOYD_PORT_RANGE_MAX", "65535")
                .parse()
                .map_err(|e| format!("DEPLOYD_PORT_RANGE_MAX: {}", e))?,
            audit_log_path: env_or("DEPLOYD_AUDIT_LOG", "/var/log/deployd/audit.log"),
            bridge_name: env_or("DEPLOYD_BRIDGE_NAME", "br-deploy"),
            caddy_admin_url: env_or("DEPLOYD_CADDY_ADMIN_URL", "http://localhost:2019"),
            caddy_server_name: env_or("DEPLOYD_CADDY_SERVER_NAME", "deployd"),
            runtime_class: env_or("DEPLOYD_RUNTIME_CLASS", "io.containerd.kata.v2"),
            nerdctl_path: env_or(
                "DEPLOYD_NERDCTL_PATH",
                "/run/current-system/sw/bin/nerdctl",
            ),
            deployd_exec_path: env_required("DEPLOYD_EXEC_PATH")?,
        })
    }
}

fn env_required(key: &str) -> Result<String, String> {
    std::env::var(key).map_err(|_| format!("{} is required but not set", key))
}

fn read_secret_file(key: &str) -> Result<String, String> {
    let path = env_required(key)?;
    std::fs::read_to_string(&path)
        .map(|s| s.trim_end().to_string())
        .map_err(|e| format!("{}: {}", path, e))
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_list(key: &str) -> Vec<String> {
    std::env::var(key)
        .unwrap_or_default()
        .split(',')
        .filter(|s| !s.is_empty())
        .map(|s| s.trim().to_string())
        .collect()
}
