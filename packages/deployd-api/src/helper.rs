use std::io::{BufRead, BufReader, Read, Write};
use vsock::{VsockStream, VsockAddr};

use serde::{Deserialize, Serialize};

/// Client for the deployd-helper vsock protocol.
pub struct HelperClient {
    vsock_port: u32,
    token: String,
}

/// Wire format matches deployd-helper's HelperMessage.
#[derive(Serialize)]
struct HelperMessage {
    token: String,
    command: HelperCommand,
}

/// Commands sent to the helper. Must match deployd-helper's HelperCommand enum.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type")]
pub enum HelperCommand {
    Deploy(ContainerDefinition),
    Teardown { name: String },
    Inspect { name: String },
    Status,
}

/// Mirrors deployd-helper's ContainerDefinition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContainerDefinition {
    pub name: String,
    pub image: String,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortMapping {
    pub host: u16,
    pub container: u16,
    #[serde(default = "default_tcp")]
    pub protocol: PortProtocol,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PortProtocol {
    Tcp,
    Udp,
}

fn default_tcp() -> PortProtocol {
    PortProtocol::Tcp
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VolumeMount {
    pub host: String,
    pub container: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IngressConfig {
    pub hostname: String,
    pub upstream_port: u16,
}

/// Response from deployd-helper.
#[derive(Debug, Clone, Deserialize)]
pub struct HelperResponse {
    pub success: bool,
    pub message: String,
    pub data: Option<serde_json::Value>,
}

// VMADDR_CID_HOST = 2: from the guest, this refers to the host.
const VMADDR_CID_HOST: u32 = 2;

impl HelperClient {
    pub fn new(vsock_port: u32, token: String) -> Self {
        Self { vsock_port, token }
    }

    /// Send a command to the helper and return its response.
    /// Uses spawn_blocking to avoid blocking the tokio runtime on vsock I/O.
    pub async fn send(&self, command: HelperCommand) -> Result<HelperResponse, String> {
        let vsock_port = self.vsock_port;
        let token = self.token.clone();

        tokio::task::spawn_blocking(move || {
            Self::send_blocking(vsock_port, &token, command)
        })
        .await
        .map_err(|e| format!("spawn_blocking failed: {}", e))?
    }

    fn send_blocking(
        vsock_port: u32,
        token: &str,
        command: HelperCommand,
    ) -> Result<HelperResponse, String> {
        let msg = HelperMessage {
            token: token.to_string(),
            command,
        };

        let addr = VsockAddr::new(VMADDR_CID_HOST, vsock_port);
        let mut stream = VsockStream::connect(&addr)
            .map_err(|e| format!("failed to connect to helper socket: {}", e))?;

        let mut payload = serde_json::to_string(&msg)
            .map_err(|e| format!("failed to serialize command: {}", e))?;
        payload.push('\n');

        stream
            .write_all(payload.as_bytes())
            .map_err(|e| format!("failed to write to helper: {}", e))?;

        let mut reader = BufReader::new(stream);
        let mut response_line = String::new();
        reader
            .take(1024 * 1024) // 1 MiB limit
            .read_line(&mut response_line)
            .map_err(|e| format!("failed to read helper response: {}", e))?;

        serde_json::from_str(&response_line)
            .map_err(|e| format!("failed to parse helper response: {}", e))
    }
}
