use crate::config::Config;
use crate::protocol::{ContainerDefinition, Runtime};

/// Validate a container definition against the configured policy.
pub fn validate_container(def: &ContainerDefinition, config: &Config) -> Result<(), String> {
    validate_name(&def.name)?;
    validate_image(&def.image, &config.registry_allowlist)?;
    validate_user(&def.user, &def.volumes)?;
    validate_ports(def, config)?;
    validate_volumes(&def.volumes)?;
    validate_env(&def.env)?;
    validate_devices(&def.devices)?;
    validate_runtime(def.runtime, &config.allowed_runtimes)?;
    if let Some(ref ingress) = def.ingress {
        validate_hostname(&ingress.hostname, &config.hostname_allowlist)?;
        validate_port_range(ingress.upstream_port, config)?;
    }
    Ok(())
}

/// Validate the requested runtime against the host allowlist.
/// None is always accepted — it resolves to the host default at execute time.
pub fn validate_runtime(requested: Option<Runtime>, allowed: &[Runtime]) -> Result<(), String> {
    if let Some(rt) = requested {
        if !allowed.contains(&rt) {
            return Err(format!(
                "runtime '{}' is not permitted on this host",
                rt.as_str()
            ));
        }
    }
    Ok(())
}

/// Validate a name (container names, Teardown target).
/// Prevents path traversal and injection.
pub fn validate_name(name: &str) -> Result<(), String> {
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

/// Validate the user field.
/// Must be a safe directory name (reuses name validation rules) when volumes
/// are present, since it's used as a path component in the volume root.
/// Empty user is allowed only when there are no volumes.
fn validate_user(user: &str, volumes: &[crate::protocol::VolumeMount]) -> Result<(), String> {
    if volumes.is_empty() {
        return Ok(());
    }
    if user.is_empty() {
        return Err("user is required when volumes are specified".into());
    }
    validate_name(user).map_err(|e| format!("user: {}", e))
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

/// Validate volume mounts.
///
/// Volume names are resolved by deployd-helper to per-user directories under
/// the volume root. Clients never specify host paths.
fn validate_volumes(
    volumes: &[crate::protocol::VolumeMount],
) -> Result<(), String> {
    for vol in volumes {
        // Volume name follows container name rules
        validate_name(&vol.name).map_err(|e| format!("volume name: {}", e))?;

        // Container path must be absolute with no traversal
        if !vol.container.starts_with('/') {
            return Err(format!(
                "volume container path '{}' must be absolute",
                vol.container
            ));
        }
        if vol.container.contains("..") {
            return Err(format!(
                "volume container path '{}' must not contain '..'",
                vol.container
            ));
        }
    }
    Ok(())
}

/// Validate a host port against the configured range.
fn validate_port_range(port: u16, config: &Config) -> Result<(), String> {
    if port < config.port_range_min || port > config.port_range_max {
        return Err(format!(
            "port {} is outside permitted range {}-{}",
            port, config.port_range_min, config.port_range_max
        ));
    }
    Ok(())
}

/// Validate a hostname against the allowlist.
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

/// Allowlist of host devices that may be exposed to containers.
///
/// Arbitrary device passthrough is a meaningful capability expansion (e.g.
/// /dev/kvm grants the ability to run nested VMs). Adding a device to this
/// list is an explicit, reviewed decision, not a per-deploy choice.
const ALLOWED_DEVICES: &[&str] = &[
    "/dev/kvm",      // nested KVM for inner VMs (e.g. NixOS test driver)
    "/dev/net/tun",  // userspace TUN/TAP for VPN/networking workloads
];

/// Validate requested host devices against the allowlist.
fn validate_devices(devices: &[String]) -> Result<(), String> {
    for dev in devices {
        if !ALLOWED_DEVICES.contains(&dev.as_str()) {
            return Err(format!(
                "device '{}' is not in the allowlist (permitted: {})",
                dev,
                ALLOWED_DEVICES.join(", ")
            ));
        }
    }
    Ok(())
}

/// Validate environment variable keys and values for quadlet file safety.
/// Rejects characters that could inject systemd unit directives.
fn validate_env(env: &std::collections::HashMap<String, String>) -> Result<(), String> {
    for (key, value) in env {
        if key.is_empty() {
            return Err("environment variable key must not be empty".into());
        }
        // Keys: only alphanumeric + underscore, must start with letter or underscore
        if !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return Err(format!(
                "environment variable key '{}' contains invalid characters (only alphanumeric and underscore allowed)",
                key
            ));
        }
        if key.starts_with(|c: char| c.is_ascii_digit()) {
            return Err(format!(
                "environment variable key '{}' must not start with a digit",
                key
            ));
        }
        // Values: reject newlines and carriage returns (could inject unit file directives)
        if value.contains('\n') || value.contains('\r') {
            return Err(format!(
                "environment variable '{}' value contains newline characters",
                key
            ));
        }
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
            vsock_host_socket: "/tmp/test-deployd.vsock".into(),
            capability_token: "test-token".into(),
            registry_allowlist: vec!["creil.internal".into()],
            hostname_allowlist: vec![".internal".into()],
            port_range_min: 1024,
            port_range_max: 65535,
            audit_log_path: "/tmp/deployd/audit.log".into(),
            bridge_name: "br-deploy".into(),
            caddy_admin_url: "http://localhost:2019".into(),
            caddy_server_name: "deployd".into(),
            allowed_runtimes: vec![Runtime::Kata, Runtime::Runc],
            default_runtime: Runtime::Kata,
            nerdctl_path: "/run/current-system/sw/bin/nerdctl".into(),
            deployd_exec_path: "/run/current-system/sw/bin/deployd-exec".into(),
            volume_root: "/tmp/deployd-test-volumes".into(),
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
            user: "testuser".into(),
            ports: vec![PortMapping {
                host: 8080,
                container: 80,
                protocol: PortProtocol::Tcp,
            }],
            env: Default::default(),
            volumes: vec![],
            persistent: false,
            ingress: None,
            memory: None,
            cpus: None,
            devices: vec![],
            runtime: None,
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
    fn test_valid_volume() {
        let vols = vec![VolumeMount {
            name: "my-volume".into(),
            container: "/data".into(),
        }];
        assert!(validate_volumes(&vols).is_ok());
    }

    #[test]
    fn test_volume_invalid_name() {
        let vols = vec![VolumeMount {
            name: "-bad-name".into(),
            container: "/data".into(),
        }];
        assert!(validate_volumes(&vols).is_err());

        let vols = vec![VolumeMount {
            name: "bad/name".into(),
            container: "/data".into(),
        }];
        assert!(validate_volumes(&vols).is_err());
    }

    #[test]
    fn test_volume_relative_container_path() {
        let vols = vec![VolumeMount {
            name: "my-volume".into(),
            container: "relative".into(),
        }];
        assert!(validate_volumes(&vols).is_err());
    }

    #[test]
    fn test_volume_container_path_traversal() {
        let vols = vec![VolumeMount {
            name: "my-volume".into(),
            container: "/data/../etc".into(),
        }];
        assert!(validate_volumes(&vols).is_err());
    }

    // --- User validation ---

    #[test]
    fn test_user_required_with_volumes() {
        let vols = vec![VolumeMount {
            name: "my-volume".into(),
            container: "/data".into(),
        }];
        assert!(validate_user("", &vols).is_err());
    }

    #[test]
    fn test_user_not_required_without_volumes() {
        assert!(validate_user("", &[]).is_ok());
    }

    #[test]
    fn test_user_valid_name() {
        let vols = vec![VolumeMount {
            name: "vol".into(),
            container: "/data".into(),
        }];
        assert!(validate_user("mutantmell", &vols).is_ok());
    }

    #[test]
    fn test_user_rejects_path_traversal() {
        let vols = vec![VolumeMount {
            name: "vol".into(),
            container: "/data".into(),
        }];
        assert!(validate_user("../../etc", &vols).is_err());
        assert!(validate_user("foo/bar", &vols).is_err());
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

    // --- Port range validation ---

    #[test]
    fn test_port_range_valid() {
        let config = test_config();
        assert!(validate_port_range(8080, &config).is_ok());
        assert!(validate_port_range(1024, &config).is_ok());
        assert!(validate_port_range(65535, &config).is_ok());
    }

    #[test]
    fn test_port_range_invalid() {
        let config = test_config();
        assert!(validate_port_range(80, &config).is_err());
        assert!(validate_port_range(443, &config).is_err());
        assert!(validate_port_range(1023, &config).is_err());
    }

    // --- Environment variable validation ---

    #[test]
    fn test_valid_env() {
        let mut env = std::collections::HashMap::new();
        env.insert("FOO".into(), "bar".into());
        env.insert("DATABASE_URL".into(), "postgres://localhost/db".into());
        env.insert("_PRIVATE".into(), "value".into());
        assert!(validate_env(&env).is_ok());
    }

    #[test]
    fn test_env_key_empty() {
        let mut env = std::collections::HashMap::new();
        env.insert("".into(), "value".into());
        assert!(validate_env(&env).is_err());
    }

    #[test]
    fn test_env_key_invalid_chars() {
        let mut env = std::collections::HashMap::new();
        env.insert("FOO-BAR".into(), "value".into());
        assert!(validate_env(&env).is_err());

        let mut env = std::collections::HashMap::new();
        env.insert("FOO.BAR".into(), "value".into());
        assert!(validate_env(&env).is_err());

        let mut env = std::collections::HashMap::new();
        env.insert("FOO BAR".into(), "value".into());
        assert!(validate_env(&env).is_err());
    }

    #[test]
    fn test_env_key_starts_with_digit() {
        let mut env = std::collections::HashMap::new();
        env.insert("1FOO".into(), "value".into());
        assert!(validate_env(&env).is_err());
    }

    // --- Device validation ---

    #[test]
    fn test_devices_empty_ok() {
        assert!(validate_devices(&[]).is_ok());
    }

    #[test]
    fn test_devices_allowlist_kvm() {
        assert!(validate_devices(&["/dev/kvm".into()]).is_ok());
    }

    #[test]
    fn test_devices_allowlist_tun() {
        assert!(validate_devices(&["/dev/net/tun".into()]).is_ok());
    }

    #[test]
    fn test_devices_rejects_arbitrary_path() {
        assert!(validate_devices(&["/dev/sda".into()]).is_err());
        assert!(validate_devices(&["/dev/mem".into()]).is_err());
        assert!(validate_devices(&["/etc/passwd".into()]).is_err());
    }

    #[test]
    fn test_devices_rejects_traversal() {
        assert!(validate_devices(&["/dev/../etc/passwd".into()]).is_err());
        assert!(validate_devices(&["/dev/kvm/../sda".into()]).is_err());
    }

    #[test]
    fn test_env_value_newline_injection() {
        let mut env = std::collections::HashMap::new();
        env.insert("FOO".into(), "bar\nExecStart=/bin/malicious".into());
        assert!(validate_env(&env).is_err());

        let mut env = std::collections::HashMap::new();
        env.insert("FOO".into(), "bar\r\nExecStart=/bin/malicious".into());
        assert!(validate_env(&env).is_err());
    }

    // --- Runtime validation ---

    #[test]
    fn test_runtime_none_always_ok() {
        assert!(validate_runtime(None, &[Runtime::Kata]).is_ok());
        assert!(validate_runtime(None, &[Runtime::Runc]).is_ok());
        assert!(validate_runtime(None, &[]).is_ok());
    }

    #[test]
    fn test_runtime_requested_and_allowed() {
        assert!(validate_runtime(Some(Runtime::Kata), &[Runtime::Kata, Runtime::Runc]).is_ok());
        assert!(validate_runtime(Some(Runtime::Runc), &[Runtime::Runc]).is_ok());
    }

    #[test]
    fn test_runtime_requested_but_not_allowed() {
        assert!(validate_runtime(Some(Runtime::Kata), &[Runtime::Runc]).is_err());
        assert!(validate_runtime(Some(Runtime::Runc), &[Runtime::Kata]).is_err());
        assert!(validate_runtime(Some(Runtime::Kata), &[]).is_err());
    }
}
