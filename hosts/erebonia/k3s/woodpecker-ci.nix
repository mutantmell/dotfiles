{
  config,
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  buildsNamespace = "woodpecker-builds";
  agentNamespace = "woodpecker-system";
  agentServiceAccount = "woodpecker-agent";
  buildStepServiceAccount = "woodpecker-build-step";
  images = import ./woodpecker-images.nix {inherit pkgs;};
  agentSecretName = "woodpecker-agent-secret";
  agentSecretKey = "WOODPECKER_AGENT_SECRET";
  agentSecretFile = config.sops.secrets.${agentSecretName}.path;

  mkEgressToHost = hostName: ports: let
    inherit ((net.forHost hostName)) host;
  in [
    {
      to = [
        {ipBlock.cidr = "${host.ipv4}/32";}
        {ipBlock.cidr = "${host.ipv6}/128";}
      ];
      inherit ports;
    }
  ];

  tcpPorts = ports:
    map (port: {
      protocol = "TCP";
      inherit port;
    })
    ports;
in {
  # k3s imports these Woodpecker platform image archives from the Nix store
  # before the agent starts. The manifests use the same image names, so
  # steady-state CI does not depend on registry pull credentials for these
  # images.
  services.k3s.images = [
    images.agent
    images.pluginGit
    images.pluginGitInternalCa
    images.busybox
    images.dotfilesCiNix
  ];

  systemd.services.k3s.restartTriggers = [images.dotfilesCiNix];

  systemd.services.woodpecker-ci-prune-old-images = {
    description = "Prune superseded Woodpecker CI image tags from k3s containerd";
    wantedBy = ["multi-user.target"];
    after = ["k3s.service"];
    wants = ["k3s.service"];
    path = [config.services.k3s.package pkgs.gawk pkgs.coreutils];
    script = ''
      set -euo pipefail

      for _ in $(seq 1 30); do
        if k3s crictl images >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done
      k3s crictl images >/dev/null

      k3s crictl images \
        | awk '$1 == "localhost/dotfiles-ci-nix" && $2 != "0.1.3" && $2 != "<none>" { print $1 ":" $2 }' \
        | while read -r image; do
            k3s crictl rmi "$image" || true
          done
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = 15;
      TimeoutStartSec = 120;
    };
  };

  sops.secrets.${agentSecretName} = {
    sopsFile = ../secrets/k3s-ca.yaml;
    key = agentSecretName;
    mode = "0400";
    restartUnits = ["woodpecker-agent-k8s-secret.service"];
  };

  systemd.services.woodpecker-agent-k8s-secret = {
    description = "Apply Woodpecker agent shared secret to k3s";
    wantedBy = ["multi-user.target"];
    after = ["k3s.service" "sops-install-secrets.service"];
    wants = ["k3s.service" "sops-install-secrets.service"];
    path = [pkgs.coreutils pkgs.kubectl];
    environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    script = ''
      set -euo pipefail

      for _ in $(seq 1 60); do
        if kubectl get namespace ${agentNamespace} >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done
      kubectl get namespace ${agentNamespace} >/dev/null

      kubectl -n ${agentNamespace} create secret generic ${agentSecretName} \
        --from-file=${agentSecretKey}=${agentSecretFile} \
        --dry-run=client \
        -o yaml \
        | kubectl apply -f -
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = 15;
      TimeoutStartSec = 180;
    };
  };

  # Woodpecker's server remains the saint-arkh microVM. The in-cluster agent is
  # only the scheduler bridge: it connects to saint-arkh over gRPC and creates
  # one pod per CI step in the restricted build namespace.
  services.k3s.manifests.woodpecker-ci.content = [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata = {
        name = agentNamespace;
        labels."app.kubernetes.io/name" = "woodpecker-agent";
      };
    }
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata = {
        name = buildsNamespace;
        labels = {
          "app.kubernetes.io/name" = "woodpecker-builds";
          "pod-security.kubernetes.io/enforce" = "restricted";
          "pod-security.kubernetes.io/audit" = "restricted";
          "pod-security.kubernetes.io/warn" = "restricted";
        };
      };
    }
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = {
        name = agentServiceAccount;
        namespace = agentNamespace;
      };
    }
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = {
        name = buildStepServiceAccount;
        namespace = buildsNamespace;
      };
      automountServiceAccountToken = false;
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = "woodpecker-agent";
        namespace = buildsNamespace;
      };
      rules = [
        {
          apiGroups = [""];
          resources = ["pods"];
          verbs = ["create" "delete" "get" "list" "watch"];
        }
        {
          apiGroups = [""];
          resources = ["pods/log"];
          verbs = ["get" "list" "watch"];
        }
        {
          apiGroups = [""];
          resources = ["services" "persistentvolumeclaims" "secrets"];
          verbs = ["create" "delete" "get" "list" "watch"];
        }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = "woodpecker-agent";
        namespace = buildsNamespace;
      };
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "woodpecker-agent";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = agentServiceAccount;
          namespace = agentNamespace;
        }
      ];
    }
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "NetworkPolicy";
      metadata = {
        name = "default-deny";
        namespace = buildsNamespace;
      };
      spec = {
        podSelector = {};
        policyTypes = ["Ingress" "Egress"];
      };
    }
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "NetworkPolicy";
      metadata = {
        name = "allow-required-egress";
        namespace = buildsNamespace;
      };
      spec = {
        podSelector = {};
        policyTypes = ["Egress"];
        egress =
          [
            {
              to = [
                {
                  namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "kube-system";
                  podSelector.matchLabels."k8s-app" = "kube-dns";
                }
              ];
              ports = [
                {
                  protocol = "UDP";
                  port = 53;
                }
                {
                  protocol = "TCP";
                  port = 53;
                }
              ];
            }
            {
              # Public HTTPS/HTTP fetches for upstream Nix substitutes and
              # image pulls. Private service egress remains listed below.
              to = [
                {
                  ipBlock = {
                    cidr = "0.0.0.0/0";
                    except = [
                      "10.0.0.0/8"
                      "172.16.0.0/12"
                      "192.168.0.0/16"
                    ];
                  };
                }
                {
                  ipBlock = {
                    cidr = "::/0";
                    except = ["fc00::/7"];
                  };
                }
              ];
              ports = tcpPorts [80 443];
            }
          ]
          ++ mkEgressToHost "creil" (tcpPorts [443])
          ++ mkEgressToHost "zeiss" (tcpPorts [443])
          ++ mkEgressToHost "saint-arkh" (tcpPorts [9000]);
      };
    }
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = "woodpecker-agent";
        namespace = agentNamespace;
        labels."app.kubernetes.io/name" = "woodpecker-agent";
      };
      spec = {
        replicas = 1;
        selector.matchLabels."app.kubernetes.io/name" = "woodpecker-agent";
        template = {
          metadata.labels."app.kubernetes.io/name" = "woodpecker-agent";
          spec = {
            serviceAccountName = agentServiceAccount;
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 1000;
              runAsGroup = 1000;
              fsGroup = 1000;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = [
              {
                name = "agent";
                image = "docker.io/woodpeckerci/woodpecker-agent:v3.15.0";
                imagePullPolicy = "IfNotPresent";
                env = [
                  {
                    name = "WOODPECKER_SERVER";
                    value = "saint-arkh.internal:9000";
                  }
                  {
                    name = "WOODPECKER_BACKEND";
                    value = "kubernetes";
                  }
                  {
                    name = "WOODPECKER_BACKEND_K8S_NAMESPACE";
                    value = buildsNamespace;
                  }
                  {
                    name = "WOODPECKER_BACKEND_K8S_STORAGE_RWX";
                    value = "false";
                  }
                  {
                    name = "WOODPECKER_BACKEND_K8S_VOLUME_SIZE";
                    value = "10G";
                  }
                  {
                    name = "WOODPECKER_BACKEND_K8S_SECCTX_NONROOT";
                    value = "true";
                  }
                  {
                    name = "WOODPECKER_BACKEND_K8S_POD_LABELS";
                    value = builtins.toJSON {
                      "app.kubernetes.io/part-of" = "woodpecker-ci";
                    };
                  }
                  {
                    name = "WOODPECKER_AGENT_CONFIG_FILE";
                    value = "/var/lib/woodpecker-agent/agent.conf";
                  }
                  {
                    name = "WOODPECKER_AGENT_SECRET";
                    valueFrom.secretKeyRef = {
                      name = agentSecretName;
                      key = agentSecretKey;
                    };
                  }
                ];
                resources = {
                  requests = {
                    cpu = "50m";
                    memory = "96Mi";
                  };
                  limits = {
                    cpu = "500m";
                    memory = "256Mi";
                  };
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = ["ALL"];
                  readOnlyRootFilesystem = true;
                };
                volumeMounts = [
                  {
                    name = "agent-state";
                    mountPath = "/var/lib/woodpecker-agent";
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "agent-state";
                emptyDir = {};
              }
            ];
          };
        };
      };
    }
  ];
}
