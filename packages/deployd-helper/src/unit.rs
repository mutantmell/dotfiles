use std::path::Path;

use crate::protocol::ContainerDefinition;

/// Resolve a volume mount to a host directory path under the volume root.
///
/// Layout: `<volume_root>/<user>/<volume_name>/`
///
/// Does NOT create the directory — callers should call `ensure_volume_dirs`
/// before generating the unit.
pub fn resolve_volume_path(volume_root: &str, user: &str, name: &str) -> String {
    Path::new(volume_root).join(user).join(name).to_string_lossy().into_owned()
}

/// Create all volume directories for a container definition.
/// Must be called before `generate_unit` so the paths exist at container start.
pub fn ensure_volume_dirs(
    def: &ContainerDefinition,
    volume_root: &str,
) -> Result<(), String> {
    for vol in &def.volumes {
        let path = Path::new(volume_root).join(&def.user).join(&vol.name);
        std::fs::create_dir_all(&path)
            .map_err(|e| format!("failed to create volume directory for '{}': {}", vol.name, e))?;
    }
    Ok(())
}

/// Generate a systemd .service file that runs a container via nerdctl/containerd.
///
/// # Why containerd instead of Podman quadlets
///
/// TODO: Switch back to Podman quadlets when Podman gains native kata-containers
/// support. Kata v3 uses the containerd shimv2 protocol (`containerd-shim-kata-v2`)
/// rather than an OCI runtime CLI binary. Podman invokes OCI runtimes directly and
/// cannot speak shimv2. containerd is the only supported container engine for kata v3.
/// Track: https://github.com/kata-containers/kata-containers/issues/722
pub fn generate_unit(
    def: &ContainerDefinition,
    runtime_class: &str,
    bridge_name: &str,
    nerdctl_path: &str,
    volume_root: &str,
) -> String {
    let mut run_args: Vec<String> = vec![
        "run".to_string(),
        "--rm".to_string(),
        format!("--name={}", def.name),
        format!("--network={}", bridge_name),
        format!("--runtime={}", runtime_class),
    ];

    for port in &def.ports {
        run_args.push(format!(
            "--publish={}:{}/{}",
            port.host, port.container, port.protocol
        ));
    }

    for (key, value) in &def.env {
        run_args.push(systemd_quote(format!("--env={}={}", key, value)));
    }

    for vol in &def.volumes {
        let host_path = resolve_volume_path(volume_root, &def.user, &vol.name);
        run_args.push(format!("--volume={}:{}", host_path, vol.container));
    }

    if let Some(ref memory) = def.memory {
        run_args.push(format!("--memory={}", memory));
    }
    if let Some(ref cpus) = def.cpus {
        run_args.push(format!("--cpus={}", cpus));
    }

    run_args.push(def.image.clone());

    format!(
        "[Unit]\n\
         Description=deployd: {name}\n\
         After=network.target containerd.service\n\
         Requires=containerd.service\n\
         \n\
         [Service]\n\
         ExecStartPre=-{nerdctl} rm -f {name}\n\
         ExecStart={nerdctl} {args}\n\
         ExecStop={nerdctl} stop {name}\n\
         Restart=on-failure\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n",
        name = def.name,
        nerdctl = nerdctl_path,
        args = run_args.join(" "),
    )
}

/// Quote a string for systemd ExecStart argument syntax.
/// Wraps in double quotes when the value contains whitespace or shell-special chars
/// that systemd's unit-file parser would otherwise split or misinterpret.
fn systemd_quote(s: String) -> String {
    if s.chars().any(|c| c.is_whitespace() || c == '"' || c == '\\' || c == ';') {
        format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{ContainerDefinition, PortMapping, PortProtocol, VolumeMount};
    use std::collections::HashMap;

    fn nerdctl() -> &'static str {
        "/run/current-system/sw/bin/nerdctl"
    }

    #[test]
    fn test_basic_unit() {
        let tmp = std::env::temp_dir().join("deployd-test-volumes-basic");
        let _ = std::fs::remove_dir_all(&tmp);
        let vol_root = tmp.to_str().unwrap();

        let def = ContainerDefinition {
            name: "myapp".into(),
            image: "creil.internal/myapp@sha256:abc123".into(),
            user: "testuser".into(),
            ports: vec![PortMapping {
                host: 8080,
                container: 80,
                protocol: PortProtocol::Tcp,
            }],
            env: {
                let mut m = HashMap::new();
                m.insert("FOO".into(), "bar".into());
                m
            },
            volumes: vec![VolumeMount {
                name: "mydata".into(),
                container: "/data".into(),
            }],
            persistent: true,
            ingress: None,
            memory: None,
            cpus: None,
        };

        // ensure_volume_dirs creates the directories (called by executor before generate_unit)
        ensure_volume_dirs(&def, vol_root).unwrap();
        assert!(tmp.join("testuser/mydata").is_dir());

        let output = generate_unit(&def, "io.containerd.kata.v2", "br-deploy", nerdctl(), vol_root);
        assert!(output.contains("Description=deployd: myapp"));
        assert!(output.contains("Requires=containerd.service"));
        assert!(output.contains("--name=myapp"));
        assert!(output.contains("--network=br-deploy"));
        assert!(output.contains("--runtime=io.containerd.kata.v2"));
        assert!(output.contains("--publish=8080:80/tcp"));
        assert!(output.contains("--env=FOO=bar"));
        let expected_vol = format!("--volume={}/testuser/mydata:/data", vol_root);
        assert!(output.contains(&expected_vol), "expected '{}' in output", expected_vol);
        assert!(output.contains("creil.internal/myapp@sha256:abc123"));
        assert!(output.contains("Restart=on-failure"));
        assert!(output.contains("WantedBy=default.target"));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_env_value_with_spaces_is_quoted() {
        let def = ContainerDefinition {
            name: "myapp".into(),
            image: "creil.internal/myapp@sha256:abc123".into(),
            user: "testuser".into(),
            ports: vec![],
            env: {
                let mut m = HashMap::new();
                m.insert("MSG".into(), "hello world".into());
                m
            },
            volumes: vec![],
            persistent: false,
            ingress: None,
            memory: None,
            cpus: None,
        };

        let output = generate_unit(&def, "io.containerd.runc.v2", "br-deploy", nerdctl(), "/tmp/vols");
        assert!(output.contains("\"--env=MSG=hello world\""));
    }

    #[test]
    fn test_runc_runtime_class() {
        let def = ContainerDefinition {
            name: "myapp".into(),
            image: "creil.internal/myapp@sha256:abc123".into(),
            user: "testuser".into(),
            ports: vec![],
            env: HashMap::new(),
            volumes: vec![],
            persistent: false,
            ingress: None,
            memory: None,
            cpus: None,
        };

        let output = generate_unit(&def, "io.containerd.runc.v2", "br-deploy", nerdctl(), "/tmp/vols");
        assert!(output.contains("--runtime=io.containerd.runc.v2"));
    }
}
