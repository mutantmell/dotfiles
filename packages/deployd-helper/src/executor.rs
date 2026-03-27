use std::fs;
use std::process::Command;
use tracing::{info, error, warn};

use crate::config::Config;
use crate::protocol::{ContainerDefinition, HelperCommand, HelperResponse};
use crate::unit::generate_unit;
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

        let unit = generate_unit(
            def,
            &self.config.runtime_class,
            &self.config.bridge_name,
            &self.config.nerdctl_path,
        );

        // Persistent containers go to /etc/systemd/system (survives reboots),
        // runtime-only containers go to /run/systemd/system (tmpfs).
        let unit_dir = if def.persistent {
            self.config.unit_persistent_dir()
        } else {
            self.config.unit_runtime_dir()
        };
        let unit_path = format!("{}/{}.service", unit_dir, def.name);

        if let Err(e) = fs::write(&unit_path, &unit) {
            return HelperResponse::err(format!("failed to write unit: {}", e));
        }
        info!(name = %def.name, path = %unit_path, persistent = def.persistent, "wrote unit");

        // daemon-reload
        if let Err(e) = self.systemctl(&["daemon-reload"]) {
            return HelperResponse::err(format!("daemon-reload failed: {}", e));
        }

        // start the service
        let service_name = format!("{}.service", def.name);
        if let Err(e) = self.systemctl(&["start", &service_name]) {
            // Clean up on start failure
            let _ = fs::remove_file(&unit_path);
            let _ = self.systemctl(&["daemon-reload"]);
            return HelperResponse::err(format!("failed to start {}: {}", service_name, e));
        }

        // Add Caddy route if ingress is configured
        if let Some(ref ingress) = def.ingress {
            if let Err(e) = self.add_caddy_route(&def.name, &ingress.hostname, ingress.upstream_port) {
                // Roll back: stop container, remove quadlet, daemon-reload
                error!(name = %def.name, error = %e, "Caddy route failed, rolling back deploy");
                let _ = self.systemctl(&["stop", &service_name]);
                let _ = fs::remove_file(&unit_path);
                let _ = self.systemctl(&["daemon-reload"]);
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

        let service_name = format!("{}.service", name);

        // Stop the service (ignore error if already stopped)
        if let Err(e) = self.systemctl(&["stop", &service_name]) {
            error!(name = %name, error = %e, "stop failed (may be already stopped)");
        }

        // Remove unit from both locations (we don't track which was used)
        let filename = format!("{}.service", name);
        let _ = fs::remove_file(format!("{}/{}", self.config.unit_runtime_dir(), filename));
        let _ = fs::remove_file(format!("{}/{}", self.config.unit_persistent_dir(), filename));

        // daemon-reload
        if let Err(e) = self.systemctl(&["daemon-reload"]) {
            return HelperResponse::err(format!("daemon-reload failed: {}", e));
        }

        // Remove Caddy route (best-effort — container may not have had ingress)
        if let Err(e) = self.remove_caddy_route(name) {
            warn!(name = %name, error = %e, "Caddy route removal failed (may not exist)");
        }

        info!(name = %name, "container torn down");
        HelperResponse::ok(format!("container '{}' torn down", name))
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

    fn inspect(&self, name: &str) -> HelperResponse {
        if let Err(e) = validation::validate_name(name) {
            return HelperResponse::err(e);
        }

        let output = Command::new(&self.config.nerdctl_path)
            .args([
                "inspect", name,
                "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
            ])
            .output();

        match output {
            Ok(out) if out.status.success() => {
                let ip = String::from_utf8_lossy(&out.stdout).trim().to_string();
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
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                HelperResponse::err(format!("nerdctl inspect failed: {}", stderr.trim()))
            }
            Err(e) => HelperResponse::err(format!("failed to run nerdctl: {}", e)),
        }
    }

    fn systemctl(&self, args: &[&str]) -> Result<(), String> {
        let output = Command::new(&self.config.systemctl_path)
            .args(args)
            .output()
            .map_err(|e| format!("failed to run systemctl: {}", e))?;

        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!(
                "systemctl {} failed: {}",
                args.join(" "),
                stderr.trim()
            ))
        }
    }
}
