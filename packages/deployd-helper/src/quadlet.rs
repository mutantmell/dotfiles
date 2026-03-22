use crate::protocol::ContainerDefinition;

/// Generate a Podman quadlet file from a validated container definition.
pub fn generate_quadlet(def: &ContainerDefinition, kata_runtime: &str, bridge_name: &str) -> String {
    let mut lines = Vec::new();

    lines.push("[Container]".to_string());
    lines.push(format!("Image={}", def.image));
    lines.push(format!("Network={}", bridge_name));
    lines.push(format!("PodmanArgs=--runtime={}", kata_runtime));

    for port in &def.ports {
        lines.push(format!(
            "PublishPort={}:{}/{}",
            port.host, port.container, port.protocol
        ));
    }

    for (key, value) in &def.env {
        lines.push(format!("Environment={}={}", key, value));
    }

    for vol in &def.volumes {
        lines.push(format!("Volume={}:{}", vol.host, vol.container));
    }

    lines.push(String::new());
    lines.push("[Service]".to_string());
    lines.push("Restart=on-failure".to_string());

    lines.push(String::new());
    lines.push("[Install]".to_string());
    lines.push("WantedBy=default.target".to_string());

    lines.join("\n") + "\n"
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{ContainerDefinition, PortMapping, PortProtocol, VolumeMount};
    use std::collections::HashMap;

    #[test]
    fn test_basic_quadlet() {
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

        let output = generate_quadlet(&def, "/run/current-system/sw/bin/kata-runtime", "br-deploy");
        assert!(output.contains("Image=creil.internal/myapp@sha256:abc123"));
        assert!(output.contains("Network=br-deploy"));
        assert!(output.contains("PodmanArgs=--runtime=/run/current-system/sw/bin/kata-runtime"));
        assert!(output.contains("PublishPort=8080:80/tcp"));
        assert!(output.contains("Environment=FOO=bar"));
        assert!(output.contains("Volume=/var/lib/myapp:/data"));
        assert!(output.contains("Restart=on-failure"));
    }
}
