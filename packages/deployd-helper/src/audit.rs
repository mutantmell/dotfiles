use chrono::Utc;
use serde::Serialize;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use tracing::error;

use crate::protocol::HelperCommand;

#[derive(Serialize)]
struct AuditEntry<'a> {
    timestamp: String,
    peer_cid: u32,
    command: &'a str,
    params: serde_json::Value,
    outcome: &'a str,
    message: &'a str,
}

/// Write an audit log entry. Never fails the calling operation — logs error and continues.
pub fn log_command(
    audit_path: &Path,
    peer_cid: u32,
    command: &HelperCommand,
    outcome: &str,
    message: &str,
) {
    let (cmd_name, params) = match command {
        HelperCommand::Deploy(def) => ("Deploy", serde_json::json!({"name": def.name, "image": def.image})),
        HelperCommand::Teardown { name } => ("Teardown", serde_json::json!({"name": name})),
        HelperCommand::Status => ("Status", serde_json::json!({})),
    };

    let entry = AuditEntry {
        timestamp: Utc::now().to_rfc3339(),
        peer_cid,
        command: cmd_name,
        params,
        outcome,
        message,
    };

    let line = match serde_json::to_string(&entry) {
        Ok(s) => s,
        Err(e) => {
            error!("failed to serialize audit entry: {}", e);
            return;
        }
    };

    let result = OpenOptions::new()
        .create(true)
        .append(true)
        .open(audit_path)
        .and_then(|mut f| writeln!(f, "{}", line));

    if let Err(e) = result {
        error!("failed to write audit log: {}", e);
    }
}
