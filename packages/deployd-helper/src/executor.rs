use std::fs;
use std::path::Path;
use std::process::Command;
use tracing::{info, error};

use crate::config::Config;
use crate::protocol::{ContainerDefinition, HelperCommand, HelperResponse, PortProtocol};
use crate::quadlet::generate_quadlet;
use crate::audit;
use crate::validation;

pub struct Executor {
    config: Config,
}

impl Executor {
    pub fn new(config: Config) -> Self {
        Self { config }
    }

    pub fn execute(&self, peer_uid: u32, command: &HelperCommand) -> HelperResponse {
        let result = self.execute_inner(command);
        let outcome = if result.success { "ok" } else { "error" };
        audit::log_command(
            Path::new(&self.config.audit_log_path),
            peer_uid,
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
            HelperCommand::AddFirewallPort { port, protocol } => {
                self.add_firewall_port(*port, *protocol)
            }
            HelperCommand::RemoveFirewallPort { port, protocol } => {
                self.remove_firewall_port(*port, *protocol)
            }
            HelperCommand::AddCaddyRoute {
                name,
                hostname,
                upstream_port,
            } => self.add_caddy_route(name, hostname, *upstream_port),
            HelperCommand::RemoveCaddyRoute { name } => self.remove_caddy_route(name),
            HelperCommand::Status => HelperResponse::ok("deployd-helper is running"),
        }
    }

    fn deploy(&self, def: &ContainerDefinition) -> HelperResponse {
        if let Err(e) = validation::validate_container(def, &self.config) {
            return HelperResponse::err(e);
        }

        let quadlet = generate_quadlet(def, &self.config.kata_runtime, &self.config.bridge_name);

        // Write to runtime dir
        let runtime_path = format!(
            "{}/{}.container",
            self.config.quadlet_runtime_dir(),
            def.name
        );
        if let Err(e) = fs::write(&runtime_path, &quadlet) {
            return HelperResponse::err(format!("failed to write runtime quadlet: {}", e));
        }
        info!(name = %def.name, path = %runtime_path, "wrote runtime quadlet");

        // Write to persistent dir if persistent
        if def.persistent {
            let persistent_path = format!(
                "{}/{}.container",
                self.config.quadlet_persistent_dir(),
                def.name
            );
            if let Err(e) = fs::write(&persistent_path, &quadlet) {
                // Clean up runtime file on failure
                let _ = fs::remove_file(&runtime_path);
                return HelperResponse::err(format!(
                    "failed to write persistent quadlet: {}",
                    e
                ));
            }
            info!(name = %def.name, path = %persistent_path, "wrote persistent quadlet");
        }

        // daemon-reload
        if let Err(e) = self.systemctl(&["daemon-reload"]) {
            return HelperResponse::err(format!("daemon-reload failed: {}", e));
        }

        // start the service
        let service_name = format!("{}.service", def.name);
        if let Err(e) = self.systemctl(&["start", &service_name]) {
            // Clean up on start failure
            let _ = fs::remove_file(&runtime_path);
            if def.persistent {
                let persistent_path = format!(
                    "{}/{}.container",
                    self.config.quadlet_persistent_dir(),
                    def.name
                );
                let _ = fs::remove_file(&persistent_path);
            }
            let _ = self.systemctl(&["daemon-reload"]);
            return HelperResponse::err(format!("failed to start {}: {}", service_name, e));
        }

        info!(name = %def.name, "container deployed successfully");
        HelperResponse::ok(format!("container '{}' deployed", def.name))
    }

    fn teardown(&self, name: &str) -> HelperResponse {
        let service_name = format!("{}.service", name);

        // Stop the service (ignore error if already stopped)
        if let Err(e) = self.systemctl(&["stop", &service_name]) {
            error!(name = %name, error = %e, "stop failed (may be already stopped)");
        }

        // Remove quadlet files
        let runtime_path = format!("{}/{}.container", self.config.quadlet_runtime_dir(), name);
        let _ = fs::remove_file(&runtime_path);

        let persistent_path = format!(
            "{}/{}.container",
            self.config.quadlet_persistent_dir(),
            name
        );
        let _ = fs::remove_file(&persistent_path);

        // daemon-reload
        if let Err(e) = self.systemctl(&["daemon-reload"]) {
            return HelperResponse::err(format!("daemon-reload failed: {}", e));
        }

        info!(name = %name, "container torn down");
        HelperResponse::ok(format!("container '{}' torn down", name))
    }

    fn add_firewall_port(&self, port: u16, protocol: PortProtocol) -> HelperResponse {
        let proto = protocol.to_string();
        let result = self.nft(&[
            "add",
            "element",
            "inet",
            &self.config.nftables_table,
            "allowed_ports",
            &format!("{{ {} }}", port),
        ]);
        match result {
            Ok(_) => {
                info!(port, protocol = %proto, "added firewall port");
                HelperResponse::ok(format!("added port {}/{}", port, proto))
            }
            Err(e) => HelperResponse::err(format!("failed to add firewall port: {}", e)),
        }
    }

    fn remove_firewall_port(&self, port: u16, protocol: PortProtocol) -> HelperResponse {
        let proto = protocol.to_string();
        let result = self.nft(&[
            "delete",
            "element",
            "inet",
            &self.config.nftables_table,
            "allowed_ports",
            &format!("{{ {} }}", port),
        ]);
        match result {
            Ok(_) => {
                info!(port, protocol = %proto, "removed firewall port");
                HelperResponse::ok(format!("removed port {}/{}", port, proto))
            }
            Err(e) => HelperResponse::err(format!("failed to remove firewall port: {}", e)),
        }
    }

    fn add_caddy_route(
        &self,
        name: &str,
        hostname: &str,
        upstream_port: u16,
    ) -> HelperResponse {
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

        match ureq::post(&url)
            .set("Content-Type", "application/json")
            .send_string(&route.to_string())
        {
            Ok(_) => {
                info!(name, hostname, upstream_port, "added Caddy route");
                HelperResponse::ok(format!("added Caddy route for {}", hostname))
            }
            Err(e) => HelperResponse::err(format!("failed to add Caddy route: {}", e)),
        }
    }

    fn remove_caddy_route(&self, name: &str) -> HelperResponse {
        let url = format!("{}/id/deployd-{}", self.config.caddy_admin_url, name);

        match ureq::delete(&url).call() {
            Ok(_) => {
                info!(name, "removed Caddy route");
                HelperResponse::ok(format!("removed Caddy route for {}", name))
            }
            Err(e) => HelperResponse::err(format!("failed to remove Caddy route: {}", e)),
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

    fn nft(&self, args: &[&str]) -> Result<(), String> {
        let output = Command::new(&self.config.nft_path)
            .args(args)
            .output()
            .map_err(|e| format!("failed to run nft: {}", e))?;

        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("nft {} failed: {}", args.join(" "), stderr.trim()))
        }
    }
}
