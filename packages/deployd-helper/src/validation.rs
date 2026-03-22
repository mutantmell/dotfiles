use crate::config::Config;
use crate::protocol::ContainerDefinition;

/// Validate a container definition against the configured policy.
pub fn validate_container(def: &ContainerDefinition, config: &Config) -> Result<(), String> {
    validate_name(&def.name)?;
    validate_image(&def.image, &config.registry_allowlist)?;
    validate_ports(def, config)?;
    validate_volumes(&def.volumes)?;
    if let Some(ref ingress) = def.ingress {
        validate_hostname(&ingress.hostname, &config.hostname_allowlist)?;
    }
    Ok(())
}

fn validate_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("container name must not be empty".into());
    }
    if name.len() > 63 {
        return Err("container name must not exceed 63 characters".into());
    }
    // Only allow DNS-safe characters — prevents path traversal, JSON injection,
    // and systemd unit name confusion (no dots, slashes, spaces, quotes).
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("container name may only contain alphanumeric characters, hyphens, and underscores".into());
    }
    if name.starts_with('-') || name.starts_with('_') {
        return Err("container name must start with an alphanumeric character".into());
    }
    Ok(())
}

fn validate_image(image: &str, allowlist: &[String]) -> Result<(), String> {
    if allowlist.is_empty() {
        return Err("registry allowlist is empty — no images are permitted".into());
    }
    let allowed = allowlist.iter().any(|prefix| image.starts_with(prefix));
    if !allowed {
        return Err(format!(
            "image '{}' does not match any permitted registry prefix",
            image
        ));
    }
    // Require digest pinning (sha256:)
    if !image.contains("@sha256:") {
        return Err("image reference must be pinned by digest (@sha256:...)".into());
    }
    Ok(())
}

fn validate_ports(def: &ContainerDefinition, config: &Config) -> Result<(), String> {
    for port in &def.ports {
        if port.host < config.port_range_min || port.host > config.port_range_max {
            return Err(format!(
                "host port {} is outside permitted range {}-{}",
                port.host, config.port_range_min, config.port_range_max
            ));
        }
    }
    Ok(())
}

/// Validate volume mount paths for safety.
/// Host paths must be absolute, normalized (no `..`), and not point to
/// sensitive system directories.
fn validate_volumes(
    volumes: &[crate::protocol::VolumeMount],
) -> Result<(), String> {
    for vol in volumes {
        // Host path must be absolute
        if !vol.host.starts_with('/') {
            return Err(format!(
                "volume host path '{}' must be absolute",
                vol.host
            ));
        }
        // Container path must be absolute
        if !vol.container.starts_with('/') {
            return Err(format!(
                "volume container path '{}' must be absolute",
                vol.container
            ));
        }
        // No path traversal components
        if vol.host.contains("..") {
            return Err(format!(
                "volume host path '{}' must not contain '..'",
                vol.host
            ));
        }
        if vol.container.contains("..") {
            return Err(format!(
                "volume container path '{}' must not contain '..'",
                vol.container
            ));
        }
        // Block access to sensitive host directories
        let blocked_prefixes = ["/etc", "/boot", "/proc", "/sys", "/dev", "/nix"];
        for prefix in &blocked_prefixes {
            if vol.host == *prefix || vol.host.starts_with(&format!("{}/", prefix)) {
                return Err(format!(
                    "volume host path '{}' is within a protected directory ({})",
                    vol.host, prefix
                ));
            }
        }
    }
    Ok(())
}

fn validate_hostname(hostname: &str, allowlist: &[String]) -> Result<(), String> {
    if allowlist.is_empty() {
        return Err("hostname allowlist is empty — no hostnames are permitted".into());
    }
    let allowed = allowlist.iter().any(|suffix| hostname.ends_with(suffix));
    if !allowed {
        return Err(format!(
            "hostname '{}' does not match any permitted hostname suffix",
            hostname
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::protocol::{PortMapping, PortProtocol, VolumeMount};

    fn test_config() -> Config {
        Config {
            socket_path: "/tmp/test.sock".into(),
            capability_token: "test-token".into(),
            allowed_uid: 1000,
            registry_allowlist: vec!["creil.internal".into()],
            hostname_allowlist: vec![".internal".into()],
            port_range_min: 1024,
            port_range_max: 65535,
            state_dir: "/tmp/deployd".into(),
            audit_log_path: "/tmp/deployd/audit.log".into(),
            bridge_name: "br-deploy".into(),
            nftables_table: "container-deploy".into(),
            caddy_admin_url: "http://localhost:2019".into(),
            caddy_server_name: "deployd".into(),
            kata_runtime: "/run/current-system/sw/bin/kata-runtime".into(),
            systemctl_path: "/run/current-system/sw/bin/systemctl".into(),
            nft_path: "/run/current-system/sw/bin/nft".into(),
        }
    }

    // --- Name validation ---

    #[test]
    fn test_valid_name() {
        assert!(validate_name("myapp").is_ok());
        assert!(validate_name("my-app").is_ok());
        assert!(validate_name("my_app").is_ok());
        assert!(validate_name("app123").is_ok());
        assert!(validate_name("a").is_ok());
    }

    #[test]
    fn test_invalid_name() {
        assert!(validate_name("").is_err());
        assert!(validate_name("-bad").is_err());
        assert!(validate_name("_bad").is_err());
        assert!(validate_name("bad name").is_err());
        assert!(validate_name("bad/name").is_err());
    }

    #[test]
    fn test_name_rejects_dots() {
        // Dots could create systemd unit confusion (e.g. "foo.bar.service")
        assert!(validate_name("foo.bar").is_err());
    }

    #[test]
    fn test_name_rejects_special_chars() {
        // Characters that could cause injection in filenames, JSON, or nftables
        assert!(validate_name("foo;bar").is_err());
        assert!(validate_name("foo\"bar").is_err());
        assert!(validate_name("foo'bar").is_err());
        assert!(validate_name("foo\nbar").is_err());
        assert!(validate_name("foo\0bar").is_err());
    }

    #[test]
    fn test_name_length_limit() {
        let long_name: String = "a".repeat(63);
        assert!(validate_name(&long_name).is_ok());
        let too_long: String = "a".repeat(64);
        assert!(validate_name(&too_long).is_err());
    }

    // --- Image validation ---

    #[test]
    fn test_valid_image() {
        let allowlist = vec!["creil.internal".into()];
        assert!(validate_image("creil.internal/myapp@sha256:abc123", &allowlist).is_ok());
    }

    #[test]
    fn test_invalid_image_registry() {
        let allowlist = vec!["creil.internal".into()];
        assert!(validate_image("docker.io/myapp@sha256:abc123", &allowlist).is_err());
    }

    #[test]
    fn test_invalid_image_no_digest() {
        let allowlist = vec!["creil.internal".into()];
        assert!(validate_image("creil.internal/myapp:latest", &allowlist).is_err());
    }

    #[test]
    fn test_image_empty_allowlist() {
        let allowlist: Vec<String> = vec![];
        assert!(validate_image("creil.internal/myapp@sha256:abc123", &allowlist).is_err());
    }

    // --- Port validation ---

    #[test]
    fn test_port_range() {
        let config = test_config();
        let def = ContainerDefinition {
            name: "test".into(),
            image: "creil.internal/test@sha256:abc".into(),
            ports: vec![PortMapping {
                host: 8080,
                container: 80,
                protocol: PortProtocol::Tcp,
            }],
            env: Default::default(),
            volumes: vec![],
            persistent: false,
            ingress: None,
            block_volume: None,
        };
        assert!(validate_ports(&def, &config).is_ok());

        let bad_def = ContainerDefinition {
            ports: vec![PortMapping {
                host: 80,
                container: 80,
                protocol: PortProtocol::Tcp,
            }],
            ..def
        };
        assert!(validate_ports(&bad_def, &config).is_err());
    }

    // --- Volume validation ---

    #[test]
    fn test_valid_volumes() {
        let vols = vec![VolumeMount {
            host: "/var/lib/myapp".into(),
            container: "/data".into(),
        }];
        assert!(validate_volumes(&vols).is_ok());
    }

    #[test]
    fn test_volume_relative_host_path() {
        let vols = vec![VolumeMount {
            host: "relative/path".into(),
            container: "/data".into(),
        }];
        assert!(validate_volumes(&vols).is_err());
    }

    #[test]
    fn test_volume_relative_container_path() {
        let vols = vec![VolumeMount {
            host: "/var/lib/myapp".into(),
            container: "relative".into(),
        }];
        assert!(validate_volumes(&vols).is_err());
    }

    #[test]
    fn test_volume_path_traversal() {
        let vols = vec![VolumeMount {
            host: "/var/lib/../etc/shadow".into(),
            container: "/data".into(),
        }];
        assert!(validate_volumes(&vols).is_err());
    }

    #[test]
    fn test_volume_blocked_directories() {
        for dir in &["/etc", "/boot", "/proc", "/sys", "/dev", "/nix"] {
            let vols = vec![VolumeMount {
                host: dir.to_string(),
                container: "/data".into(),
            }];
            assert!(
                validate_volumes(&vols).is_err(),
                "should block {}",
                dir
            );

            let vols = vec![VolumeMount {
                host: format!("{}/foo", dir),
                container: "/data".into(),
            }];
            assert!(
                validate_volumes(&vols).is_err(),
                "should block {}/foo",
                dir
            );
        }
    }

    // --- Hostname validation ---

    #[test]
    fn test_valid_hostname() {
        let allowlist = vec![".internal".into()];
        assert!(validate_hostname("myapp.internal", &allowlist).is_ok());
    }

    #[test]
    fn test_invalid_hostname() {
        let allowlist = vec![".internal".into()];
        assert!(validate_hostname("myapp.external.com", &allowlist).is_err());
    }

    #[test]
    fn test_hostname_empty_allowlist() {
        let allowlist: Vec<String> = vec![];
        assert!(validate_hostname("myapp.internal", &allowlist).is_err());
    }
}
