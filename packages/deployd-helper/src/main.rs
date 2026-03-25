mod audit;
mod config;
mod executor;
mod protocol;
mod quadlet;
mod validation;

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixListener;
use std::os::unix::net::UnixStream;
use std::path::Path;
use tracing::{error, info, warn};
use subtle::ConstantTimeEq;

use config::Config;
use executor::Executor;
use protocol::{HelperMessage, HelperResponse};

/// Maximum allowed message size (1 MiB). Prevents memory exhaustion from
/// a compromised or misbehaving client sending unbounded data.
const MAX_MESSAGE_SIZE: usize = 1_048_576;

fn main() {
    tracing_subscriber::fmt()
        .with_target(false)
        .json()
        .init();

    let config = match Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            error!("configuration error: {}", e);
            std::process::exit(1);
        }
    };

    // cloud-hypervisor proxies guest vsock connections to this Unix socket.
    // Remove any stale socket from a previous run.
    let socket_path = Path::new(&config.vsock_host_socket);
    if socket_path.exists() {
        if let Err(e) = std::fs::remove_file(socket_path) {
            error!("failed to remove stale socket: {}", e);
            std::process::exit(1);
        }
    }

    let listener = match UnixListener::bind(socket_path) {
        Ok(l) => l,
        Err(e) => {
            error!("failed to bind socket at {}: {}", config.vsock_host_socket, e);
            std::process::exit(1);
        }
    };

    // Restrict to deployd-helper group (0660): only cloud-hypervisor (microvm user,
    // member of deployd-helper group) can connect — restores defense-in-depth.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o660);
        if let Err(e) = std::fs::set_permissions(socket_path, perms) {
            error!("failed to set socket permissions: {}", e);
            std::process::exit(1);
        }
    }

    let executor = Executor::new(config.clone());

    info!(socket = %config.vsock_host_socket, "deployd-helper listening");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                info!("accepted connection");
                handle_connection(stream, &config, &executor);
            }
            Err(e) => {
                error!("accept failed: {}", e);
            }
        }
    }
}

fn handle_connection(
    stream: UnixStream,
    config: &Config,
    executor: &Executor,
) {
    let mut reader = BufReader::new(&stream);

    loop {
        let mut line = String::new();

        match reader.by_ref().take((MAX_MESSAGE_SIZE + 1) as u64).read_line(&mut line) {
            Ok(0) => break, // EOF
            Ok(_) => {}
            Err(e) => {
                error!("read error: {}", e);
                break;
            }
        }

        let line = line.trim_end_matches('\n').trim_end_matches('\r');

        if line.is_empty() {
            continue;
        }

        if line.len() > MAX_MESSAGE_SIZE {
            warn!(size = line.len(), "rejecting oversized message");
            let resp = HelperResponse::err("message exceeds maximum size");
            let _ = write_response(&stream, &resp);
            continue;
        }

        let msg: HelperMessage = match serde_json::from_str(&line) {
            Ok(m) => m,
            Err(e) => {
                warn!("invalid message: {}", e);
                let resp = HelperResponse::err(format!("invalid message format: {}", e));
                let _ = write_response(&stream, &resp);
                continue;
            }
        };

        // Validate capability token (constant-time comparison via subtle crate)
        if msg.token.as_bytes().ct_eq(config.capability_token.as_bytes()).unwrap_u8() != 1 {
            warn!("invalid capability token");
            let resp = HelperResponse::err("invalid capability token");
            let _ = write_response(&stream, &resp);
            continue;
        }

        // Use 0 as the peer identifier in audit log (CID not available via Unix socket proxy)
        let response = executor.execute(0, &msg.command);
        if let Err(e) = write_response(&stream, &response) {
            error!("failed to write response: {}", e);
            break;
        }
    }
}

fn write_response(stream: &UnixStream, response: &HelperResponse) -> Result<(), String> {
    let mut stream = stream;
    let line = serde_json::to_string(response).map_err(|e| format!("serialize error: {}", e))?;
    writeln!(stream, "{}", line).map_err(|e| format!("write error: {}", e))
}
