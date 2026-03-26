use crate::protocol::ContainerDefinition;

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
        run_args.push(format!("--volume={}:{}", vol.host, vol.container));
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
        let def = ContainerDefinition {
            name: "myapp".into(),
            image: "creil.internal/myapp@sha256:abc123".into(),
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
                host: "/var/lib/myapp".into(),
                container: "/data".into(),
            }],
            persistent: true,
            ingress: None,
        };

        let output = generate_unit(&def, "io.containerd.kata.v2", "br-deploy", nerdctl());
        assert!(output.contains("Description=deployd: myapp"));
        assert!(output.contains("Requires=containerd.service"));
        assert!(output.contains("--name=myapp"));
        assert!(output.contains("--network=br-deploy"));
        assert!(output.contains("--runtime=io.containerd.kata.v2"));
        assert!(output.contains("--publish=8080:80/tcp"));
        assert!(output.contains("--env=FOO=bar"));
        assert!(output.contains("--volume=/var/lib/myapp:/data"));
        assert!(output.contains("creil.internal/myapp@sha256:abc123"));
        assert!(output.contains("Restart=on-failure"));
        assert!(output.contains("WantedBy=default.target"));
    }

    #[test]
    fn test_env_value_with_spaces_is_quoted() {
        let def = ContainerDefinition {
            name: "myapp".into(),
            image: "creil.internal/myapp@sha256:abc123".into(),
            ports: vec![],
            env: {
                let mut m = HashMap::new();
                m.insert("MSG".into(), "hello world".into());
                m
            },
            volumes: vec![],
            persistent: false,
            ingress: None,
        };

        let output = generate_unit(&def, "io.containerd.runc.v2", "br-deploy", nerdctl());
        assert!(output.contains("\"--env=MSG=hello world\""));
    }

    #[test]
    fn test_runc_runtime_class() {
        let def = ContainerDefinition {
            name: "myapp".into(),
            image: "creil.internal/myapp@sha256:abc123".into(),
            ports: vec![],
            env: HashMap::new(),
            volumes: vec![],
            persistent: false,
            ingress: None,
        };

        let output = generate_unit(&def, "io.containerd.runc.v2", "br-deploy", nerdctl());
        assert!(output.contains("--runtime=io.containerd.runc.v2"));
    }
}
