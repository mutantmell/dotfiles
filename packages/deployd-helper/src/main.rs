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
use subtle::ConstantTimeEq;
use tracing::{error, info, warn};

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

    // Clean up stale socket
    let socket_path = Path::new(&config.socket_path);
    if socket_path.exists() {
        if let Err(e) = std::fs::remove_file(socket_path) {
            error!("failed to remove stale socket: {}", e);
            std::process::exit(1);
        }
    }

    let listener = match UnixListener::bind(socket_path) {
        Ok(l) => l,
        Err(e) => {
            error!("failed to bind socket at {}: {}", config.socket_path, e);
            std::process::exit(1);
        }
    };

    // Set socket permissions so the deployd user can connect
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

    info!(socket = %config.socket_path, "deployd-helper listening");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let peer_uid = match get_peer_uid(&stream) {
                    Ok(uid) => uid,
                    Err(e) => {
                        warn!("failed to get peer credentials: {}", e);
                        continue;
                    }
                };

                // SO_PEERCRED: if an allowed UID is configured, only accept
                // that UID (plus root for operational debugging). When no UID
                // filter is set, any UID can connect — capability token is
                // still required on every message regardless.
                if let Some(allowed) = config.allowed_uid {
                    if peer_uid != allowed && peer_uid != 0 {
                        warn!(peer_uid, "rejecting connection from unauthorized UID");
                        continue;
                    }
                }

                info!(peer_uid, "accepted connection");

                handle_connection(stream, peer_uid, &config, &executor);
            }
            Err(e) => {
                error!("accept failed: {}", e);
            }
        }
    }
}

fn get_peer_uid(stream: &UnixStream) -> Result<u32, String> {
    use std::os::unix::io::AsRawFd;

    let fd = stream.as_raw_fd();
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;

    let ret = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut cred as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };

    if ret == 0 {
        Ok(cred.uid)
    } else {
        Err(format!(
            "getsockopt SO_PEERCRED failed: {}",
            std::io::Error::last_os_error()
        ))
    }
}

fn handle_connection(
    stream: UnixStream,
    peer_uid: u32,
    config: &Config,
    executor: &Executor,
) {
    let mut reader = BufReader::new(&stream);

    loop {
        let mut line = String::new();

        // Read one line, enforcing MAX_MESSAGE_SIZE as a hard limit on memory.
        // BufReader::read_line() appends to the buffer, so we use take() to
        // cap the read at MAX_MESSAGE_SIZE + 1 bytes, allowing us to detect
        // oversized messages without buffering them entirely.
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
            warn!(peer_uid, "invalid capability token");
            let resp = HelperResponse::err("invalid capability token");
            let _ = write_response(&stream, &resp);
            continue;
        }

        let response = executor.execute(peer_uid, &msg.command);
        if let Err(e) = write_response(&stream, &response) {
            error!("failed to write response: {}", e);
            break;
        }
    }
}

fn write_response(
    stream: &UnixStream,
    response: &HelperResponse,
) -> Result<(), String> {
    let mut stream = stream;
    let line = serde_json::to_string(response).map_err(|e| format!("serialize error: {}", e))?;
    writeln!(stream, "{}", line).map_err(|e| format!("write error: {}", e))
}
