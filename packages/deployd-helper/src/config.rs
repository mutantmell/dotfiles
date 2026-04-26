use serde::Deserialize;

use crate::protocol::Runtime;

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
    /// Runtimes permitted on this host. Clients may request any of these per-deploy.
    pub allowed_runtimes: Vec<Runtime>,
    /// Runtime used when a deploy request omits the runtime field.
    pub default_runtime: Runtime,
    /// Path to nerdctl, embedded in generated systemd unit files (not called directly).
    pub nerdctl_path: String,
    /// Path to the deployd-exec privileged wrapper script (invoked via sudo).
    pub deployd_exec_path: String,
    /// Root directory for managed volumes. Per-user subdirectories are created
    /// automatically (e.g. <volume_root>/<user>/<volume_name>/).
    pub volume_root: String,
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
            allowed_runtimes: parse_runtime_list("DEPLOYD_ALLOWED_RUNTIMES")?,
            default_runtime: parse_runtime("DEPLOYD_DEFAULT_RUNTIME")?,
            nerdctl_path: env_or(
                "DEPLOYD_NERDCTL_PATH",
                "/run/current-system/sw/bin/nerdctl",
            ),
            deployd_exec_path: env_required("DEPLOYD_EXEC_PATH")?,
            volume_root: env_or("DEPLOYD_VOLUME_ROOT", "/var/lib/deployd/volumes"),
        })
    }
}

fn parse_runtime(key: &str) -> Result<Runtime, String> {
    let s = env_required(key)?;
    match s.as_str() {
        "kata" => Ok(Runtime::Kata),
        "runc" => Ok(Runtime::Runc),
        other => Err(format!("{}: unknown runtime '{}'", key, other)),
    }
}

fn parse_runtime_list(key: &str) -> Result<Vec<Runtime>, String> {
    let s = std::env::var(key).map_err(|_| format!("{} is required but not set", key))?;
    s.split(',')
        .filter(|x| !x.is_empty())
        .map(|x| match x.trim() {
            "kata" => Ok(Runtime::Kata),
            "runc" => Ok(Runtime::Runc),
            other => Err(format!("{}: unknown runtime '{}'", key, other)),
        })
        .collect()
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
