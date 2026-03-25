mod audit;
mod config;
mod executor;
mod protocol;
mod quadlet;
mod validation;

use std::io::{BufRead, BufReader, Read, Write};
use tracing::{error, info, warn};
use vsock::{VsockListener, VsockAddr, VMADDR_CID_ANY};
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

    let addr = VsockAddr::new(VMADDR_CID_ANY, config.vsock_port);
    let listener = match VsockListener::bind(&addr) {
        Ok(l) => l,
        Err(e) => {
            error!("failed to bind vsock port {}: {}", config.vsock_port, e);
            std::process::exit(1);
        }
    };

    let executor = Executor::new(config.clone());

    info!(vsock_port = config.vsock_port, "deployd-helper listening");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let peer_cid = match stream.peer_addr() {
                    Ok(addr) => addr.cid(),
                    Err(e) => {
                        warn!("failed to get peer address: {}", e);
                        continue;
                    }
                };

                if peer_cid != config.vsock_allowed_cid {
                    warn!(peer_cid, allowed = config.vsock_allowed_cid, "rejecting connection from unauthorized CID");
                    continue;
                }

                info!(peer_cid, "accepted connection");
                handle_connection(stream, peer_cid, &config, &executor);
            }
            Err(e) => {
                error!("accept failed: {}", e);
            }
        }
    }
}

fn handle_connection(
    stream: vsock::VsockStream,
    peer_cid: u32,
    config: &Config,
    executor: &Executor,
) {
    let mut writer = match stream.try_clone() {
        Ok(w) => w,
        Err(e) => {
            error!("failed to clone vsock stream: {}", e);
            return;
        }
    };
    let mut reader = BufReader::new(stream);

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
            let _ = write_response(&mut writer, &resp);
            continue;
        }

        let msg: HelperMessage = match serde_json::from_str(&line) {
            Ok(m) => m,
            Err(e) => {
                warn!("invalid message: {}", e);
                let resp = HelperResponse::err(format!("invalid message format: {}", e));
                let _ = write_response(&mut writer, &resp);
                continue;
            }
        };

        // Validate capability token (constant-time comparison via subtle crate)
        if msg.token.as_bytes().ct_eq(config.capability_token.as_bytes()).unwrap_u8() != 1 {
            warn!(peer_cid, "invalid capability token");
            let resp = HelperResponse::err("invalid capability token");
            let _ = write_response(&mut writer, &resp);
            continue;
        }

        let response = executor.execute(peer_cid, &msg.command);
        if let Err(e) = write_response(&mut writer, &response) {
            error!("failed to write response: {}", e);
            break;
        }
    }
}

fn write_response(
    writer: &mut vsock::VsockStream,
    response: &HelperResponse,
) -> Result<(), String> {
    let line = serde_json::to_string(response).map_err(|e| format!("serialize error: {}", e))?;
    writeln!(writer, "{}", line).map_err(|e| format!("write error: {}", e))
}
