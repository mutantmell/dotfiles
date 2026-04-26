use std::process::Command;
use tracing::{info, error, warn};

use crate::config::Config;
use crate::protocol::{ContainerDefinition, HelperCommand, HelperResponse};
use crate::unit::{generate_unit, ensure_volume_dirs};
use crate::audit;
use crate::validation;

pub struct Executor {
    config: Config,
}

impl Executor {
    pub fn new(config: Config) -> Self {
        Self { config }
    }

    pub fn execute(&self, peer_cid: u32, command: &HelperCommand) -> HelperResponse {
        let result = self.execute_inner(command);
        let outcome = if result.success { "ok" } else { "error" };
        audit::log_command(
            std::path::Path::new(&self.config.audit_log_path),
            peer_cid,
            command,
            outcome,
            &result.message,
        );
        result
    }

    fn execute_inner(&self, command: &HelperCommand) -> HelperResponse {
        match command {
            HelperCommand::Deploy(def) => self.deploy(def),
            HelperCommand::Teardown { name } => self.teardown(name),
            HelperCommand::Inspect { name } => self.inspect(name),
            HelperCommand::Status => HelperResponse::ok("deployd-helper is running"),
        }
    }

    fn deploy(&self, def: &ContainerDefinition) -> HelperResponse {
        if let Err(e) = validation::validate_container(def, &self.config) {
            return HelperResponse::err(e);
        }

        if let Err(e) = ensure_volume_dirs(def, &self.config.volume_root) {
            return HelperResponse::err(e);
        }

        let runtime = def.runtime.unwrap_or(self.config.default_runtime);
        let unit = generate_unit(
            def,
            runtime.runtime_class(),
            &self.config.bridge_name,
            &self.config.nerdctl_path,
            &self.config.volume_root,
        );

        // Pipe unit content to deployd-exec write-unit via stdin
        let mut write_args = vec!["write-unit", &def.name];
        if def.persistent {
            write_args.push("--persistent");
        }
        if let Err(e) = self.deployd_exec_stdin(&write_args, &unit) {
            return HelperResponse::err(format!("failed to write unit: {}", e));
        }

        // Start the service
        if let Err(e) = self.deployd_exec(&["start", &def.name]) {
            // Clean up on start failure
            let _ = self.deployd_exec(&["remove-unit", &def.name]);
            return HelperResponse::err(format!("failed to start {}: {}", def.name, e));
        }

        // Add Caddy route if ingress is configured
        if let Some(ref ingress) = def.ingress {
            if let Err(e) = self.add_caddy_route(&def.name, &ingress.hostname, ingress.upstream_port) {
                error!(name = %def.name, error = %e, "Caddy route failed, rolling back deploy");
                let _ = self.deployd_exec(&["stop", &def.name]);
                let _ = self.deployd_exec(&["remove-unit", &def.name]);
                return HelperResponse::err(format!("failed to add Caddy route: {}", e));
            }
        }

        info!(name = %def.name, "container deployed successfully");
        HelperResponse::ok(format!("container '{}' deployed", def.name))
    }

    fn teardown(&self, name: &str) -> HelperResponse {
        if let Err(e) = validation::validate_name(name) {
            return HelperResponse::err(e);
        }

        // Stop the service (ignore error if already stopped)
        if let Err(e) = self.deployd_exec(&["stop", name]) {
            error!(name = %name, error = %e, "stop failed (may be already stopped)");
        }

        // Remove unit file and daemon-reload
        if let Err(e) = self.deployd_exec(&["remove-unit", name]) {
            return HelperResponse::err(format!("remove-unit failed: {}", e));
        }

        // Remove Caddy route (best-effort — container may not have had ingress)
        if let Err(e) = self.remove_caddy_route(name) {
            warn!(name = %name, error = %e, "Caddy route removal failed (may not exist)");
        }

        info!(name = %name, "container torn down");
        HelperResponse::ok(format!("container '{}' torn down", name))
    }

    fn inspect(&self, name: &str) -> HelperResponse {
        if let Err(e) = validation::validate_name(name) {
            return HelperResponse::err(e);
        }

        match self.deployd_exec(&["inspect", name]) {
            Ok(output) => {
                let ip = output.trim().to_string();
                if ip.is_empty() {
                    HelperResponse {
                        success: true,
                        message: format!("container '{}' has no IP yet", name),
                        data: None,
                    }
                } else {
                    HelperResponse {
                        success: true,
                        message: format!("container '{}' inspected", name),
                        data: Some(serde_json::json!({"ip": ip})),
                    }
                }
            }
            Err(e) => HelperResponse::err(format!("inspect failed: {}", e)),
        }
    }

    fn add_caddy_route(
        &self,
        name: &str,
        hostname: &str,
        upstream_port: u16,
    ) -> Result<(), String> {
        let route = serde_json::json!({
            "@id": format!("deployd-{}", name),
            "match": [{"host": [hostname]}],
            "handle": [{
                "handler": "reverse_proxy",
                "upstreams": [{"dial": format!("localhost:{}", upstream_port)}]
            }],
            "terminal": true
        });

        let url = format!(
            "{}/config/apps/http/servers/{}/routes",
            self.config.caddy_admin_url, self.config.caddy_server_name
        );

        ureq::post(&url)
            .set("Content-Type", "application/json")
            .send_string(&route.to_string())
            .map_err(|e| format!("Caddy API error: {}", e))?;

        info!(name, hostname, upstream_port, "added Caddy route");
        Ok(())
    }

    fn remove_caddy_route(&self, name: &str) -> Result<(), String> {
        let url = format!("{}/id/deployd-{}", self.config.caddy_admin_url, name);

        ureq::delete(&url)
            .call()
            .map_err(|e| format!("Caddy API error: {}", e))?;

        info!(name, "removed Caddy route");
        Ok(())
    }

    /// Run deployd-exec via sudo and return stdout on success.
    fn deployd_exec(&self, args: &[&str]) -> Result<String, String> {
        let output = Command::new("sudo")
            .arg(&self.config.deployd_exec_path)
            .args(args)
            .output()
            .map_err(|e| format!("failed to run deployd-exec: {}", e))?;

        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!(
                "deployd-exec {} failed: {}",
                args.join(" "),
                stderr.trim()
            ))
        }
    }

    /// Run deployd-exec via sudo, piping data to stdin.
    fn deployd_exec_stdin(&self, args: &[&str], stdin_data: &str) -> Result<String, String> {
        use std::io::Write;
        use std::process::Stdio;

        let mut child = Command::new("sudo")
            .arg(&self.config.deployd_exec_path)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("failed to spawn deployd-exec: {}", e))?;

        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(stdin_data.as_bytes())
                .map_err(|e| format!("failed to write to deployd-exec stdin: {}", e))?;
        }

        let output = child
            .wait_with_output()
            .map_err(|e| format!("failed to wait for deployd-exec: {}", e))?;

        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!(
                "deployd-exec {} failed: {}",
                args.join(" "),
                stderr.trim()
            ))
        }
    }
}
