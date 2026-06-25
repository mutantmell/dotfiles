{
  config,
  pkgs,
  lib,
  ...
}: let
  namespace = "woodpecker-ci-workers";
  vmName = "woodpecker-ci-worker";
  cloudInitSecretName = "${vmName}-cloud-init";
  agentSecretName = "woodpecker-agent-secret";
  agentSecretFile = config.sops.secrets.${agentSecretName}.path;
in {
  sops.secrets.${agentSecretName}.restartUnits = ["woodpecker-ci-worker-cloud-init-secret.service"];

  systemd.services.woodpecker-ci-worker-cloud-init-secret = {
    description = "Apply Woodpecker CI worker cloud-init secret to k3s";
    wantedBy = ["multi-user.target"];
    after = ["k3s.service" "sops-install-secrets.service"];
    wants = ["k3s.service" "sops-install-secrets.service"];
    path = [pkgs.coreutils pkgs.kubectl];
    environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    script = ''
      set -euo pipefail

      for _ in $(seq 1 60); do
        if kubectl get namespace ${namespace} >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done
      kubectl get namespace ${namespace} >/dev/null

      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      token=$(tr -d '\n' < ${agentSecretFile})
      {
        printf '%s\n' '#cloud-config'
        printf '%s\n' 'write_files:'
        printf '%s\n' '  - path: /etc/woodpecker/agent.env'
        printf '%s\n' '    owner: root:root'
        printf '%s\n' "    permissions: '0400'"
        printf '%s\n' '    content: |'
        printf '      WOODPECKER_AGENT_SECRET=%s\n' "$token"
      } > "$tmp/userdata"

      kubectl -n ${namespace} create secret generic ${cloudInitSecretName} \
        --from-file=userdata="$tmp/userdata" \
        --dry-run=client \
        -o yaml \
        | kubectl apply -f -

      kubectl -n ${namespace} delete vmi ${vmName} --ignore-not-found
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = 15;
      TimeoutStartSec = 180;
    };
  };

  services.k3s.manifests.woodpecker-ci-worker-vm.content = [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata = {
        name = namespace;
        labels."app.kubernetes.io/name" = "woodpecker-ci-worker";
      };
    }
    {
      apiVersion = "kubevirt.io/v1";
      kind = "VirtualMachine";
      metadata = {
        name = vmName;
        inherit namespace;
        labels."app.kubernetes.io/name" = "woodpecker-ci-worker";
      };
      spec = {
        runStrategy = "Always";
        template = {
          metadata.labels."app.kubernetes.io/name" = "woodpecker-ci-worker";
          spec = {
            terminationGracePeriodSeconds = 30;
            domain = {
              cpu = {
                model = "host-passthrough";
                cores = 4;
              };
              resources.requests.memory = "6Gi";
              devices = {
                disks = [
                  {
                    name = "rootdisk";
                    disk.bus = "virtio";
                  }
                  {
                    name = "scratch";
                    serial = "scratch";
                    disk.bus = "virtio";
                  }
                  {
                    name = "cloudinit";
                    disk.bus = "virtio";
                  }
                ];
                interfaces = [
                  {
                    name = "default";
                    masquerade = {};
                  }
                ];
              };
            };
            networks = [
              {
                name = "default";
                pod = {};
              }
            ];
            volumes = [
              {
                name = "rootdisk";
                containerDisk = {
                  image = "localhost/ci-worker-base:latest";
                  imagePullPolicy = "IfNotPresent";
                };
              }
              {
                name = "scratch";
                emptyDisk.capacity = "100Gi";
              }
              {
                name = "cloudinit";
                cloudInitNoCloud.secretRef.name = cloudInitSecretName;
              }
            ];
          };
        };
      };
    }
  ];
}
