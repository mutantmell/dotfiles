use serde::{Deserialize, Serialize};

/// Wire protocol between deployd API (microVM) and deployd-helper (host).
/// Each message is a newline-delimited JSON object prefixed by a capability token.

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HelperMessage {
    pub token: String,
    pub command: HelperCommand,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum HelperCommand {
    Deploy(ContainerDefinition),
    Teardown {
        name: String,
    },
    Inspect {
        name: String,
    },
    Status,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContainerDefinition {
    pub name: String,
    pub image: String,
    /// User who initiated the deploy (injected by deployd-api from OAuth claims).
    #[serde(default)]
    pub user: String,
    #[serde(default)]
    pub ports: Vec<PortMapping>,
    #[serde(default)]
    pub env: std::collections::HashMap<String, String>,
    #[serde(default)]
    pub volumes: Vec<VolumeMount>,
    #[serde(default)]
    pub persistent: bool,
    pub ingress: Option<IngressConfig>,
    /// Memory limit (e.g. "2g", "512m"). Passed as --memory to nerdctl.
    #[serde(default)]
    pub memory: Option<String>,
    /// CPU limit (e.g. "2.0", "0.5"). Passed as --cpus to nerdctl.
    #[serde(default)]
    pub cpus: Option<String>,
    /// Host devices to expose inside the container (e.g. "/dev/kvm" for nested
    /// virtualization). Each entry becomes a `--device=PATH` flag. Restricted
    /// by validation to a small allowlist; arbitrary device passthrough is not
    /// permitted.
    #[serde(default)]
    pub devices: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortMapping {
    pub host: u16,
    pub container: u16,
    #[serde(default = "default_tcp")]
    pub protocol: PortProtocol,
}

fn default_tcp() -> PortProtocol {
    PortProtocol::Tcp
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PortProtocol {
    Tcp,
    Udp,
}

impl std::fmt::Display for PortProtocol {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PortProtocol::Tcp => write!(f, "tcp"),
            PortProtocol::Udp => write!(f, "udp"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VolumeMount {
    /// Volume name — resolved to a host directory by deployd-helper under
    /// the per-user volume root (e.g. /var/lib/deployd/volumes/<user>/<name>).
    pub name: String,
    /// Absolute mount target inside the container.
    pub container: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IngressConfig {
    pub hostname: String,
    pub upstream_port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HelperResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

impl HelperResponse {
    pub fn ok(message: impl Into<String>) -> Self {
        Self {
            success: true,
            message: message.into(),
            data: None,
        }
    }

    pub fn err(message: impl Into<String>) -> Self {
        Self {
            success: false,
            message: message.into(),
            data: None,
        }
    }
}
