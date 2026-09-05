{pkgs}: let
  vmManifest = pkgs.writeText "dev-machine-vm.json" (builtins.toJSON {
    apiVersion = "kubevirt.io/v1";
    kind = "VirtualMachine";
    metadata = {
      name = "PLACEHOLDER";
      namespace = "PLACEHOLDER";
      labels.app = "dev-machine";
    };
    spec = {
      runStrategy = "Always";
      template = {
        metadata.labels = {
          app = "dev-machine";
          dev-machine = "PLACEHOLDER";
        };
        spec = {
          terminationGracePeriodSeconds = 5;
          domain = {
            cpu = {
              model = "host-passthrough";
              cores = 4;
            };
            resources.requests.memory = "16Gi";
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
              ];
              interfaces = [
                {
                  name = "cluster";
                  binding.name = "macvtap";
                  macAddress = "PLACEHOLDER";
                }
              ];
            };
          };
          networks = [
            {
              name = "cluster";
              multus.networkName = "PLACEHOLDER";
            }
          ];
          accessCredentials = [
            {
              sshPublicKey = {
                source.secret.secretName = "PLACEHOLDER";
                propagationMethod.qemuGuestAgent.users = ["dev"];
              };
            }
          ];
          volumes = [
            {
              name = "rootdisk";
              containerDisk = {
                image = "PLACEHOLDER";
                imagePullPolicy = "Always";
              };
            }
            {
              name = "scratch";
              emptyDisk.capacity = "60Gi";
            }
          ];
        };
      };
    };
  });
in
  pkgs.writeShellApplication {
    name = "dev-machine";
    runtimeInputs = with pkgs; [
      kubectl
      kubevirt
      devpod
      skopeo
      openssh
      curl
      git
      jq
      python3
      coreutils
      findutils
      gnugrep
      gnused
      gnutar
      gzip
      gawk
    ];
    text = ''
      CONFIG_FILE="''${DEV_MACHINE_CONFIG:-''${XDG_CONFIG_HOME:-$HOME/.config}/dev-machine/config.json}"

      json_string() {
          local expr=$1 default=''${2:-}
          if [[ -f "$CONFIG_FILE" ]]; then
              jq -er "$expr // empty" "$CONFIG_FILE" 2>/dev/null || printf '%s\n' "$default"
          else
              printf '%s\n' "$default"
          fi
      }

      json_bool() {
          local expr=$1 default=$2
          if [[ -f "$CONFIG_FILE" ]]; then
              jq -er "($expr) as \$v | if (\$v == null) then $default elif \$v then \"true\" else \"false\" end" "$CONFIG_FILE" 2>/dev/null || printf '%s\n' "$default"
          else
              printf '%s\n' "$default"
          fi
      }

      load_config() {
          local registry ssh_pubkey
          NAMESPACE=$(json_string '.namespace' 'dev-machines')
          registry=$(json_string '.registry' 'forgejo.internal/mutantmell')
          BASE_IMAGE="$registry/dev-machine-base:latest"
          DEV_IMAGE="$registry/dev-machine-dev:latest"
          REGISTRY_HOST="''${registry%%/*}"
          FLAKE=$(json_string '.flake' "$HOME/git/dotfiles")
          KUBECONFIG=$(json_string '.kubeconfig' "$HOME/.kube/erebonia-oidc.yaml")
          DEFAULT_MEMORY=$(json_string '.defaultMemory' '16Gi')
          DEFAULT_CPU=$(json_string '.defaultCpu' '4')
          DEFAULT_DISK=$(json_string '.defaultDisk' '60Gi')
          VM_MANIFEST="${vmManifest}"
          FORGEJO_API=$(json_string '.forgejoApi' 'https://forgejo.internal/api/v1')
          FORGEJO_USER=$(json_string '.forgejoUser' 'cc')
          FORGEJO_TOKEN_FILE=$(json_string '.forgejoTokenFile' "")
          WOODPECKER_SERVER=$(json_string '.woodpeckerServer' 'https://woodpecker.internal')
          WOODPECKER_TOKEN_FILE=$(json_string '.woodpeckerTokenFile' "")
          COMMIT_NAME=$(json_string '.commitName' "$FORGEJO_USER")
          COMMIT_EMAIL=$(json_string '.commitEmail' "$FORGEJO_USER@forgejo.internal")
          AGENTS_DOTFILES_ENABLE=$(json_bool '.agentsDotfiles.enable' true)
          AGENTS_DOTFILES_URL=$(json_string '.agentsDotfiles.url' "")
          AGENTS_DOTFILES_SCRIPT=$(json_string '.agentsDotfiles.script' 'install.sh')
          AGENTS_MANIFEST_PATH=".net.mutantmell/agents.toml"
          STATE="''${XDG_STATE_HOME:-$HOME/.local/state}/dev-machine"

          SSH_PUBKEYS=()
          if [[ -f "$CONFIG_FILE" ]]; then
              readarray -t SSH_PUBKEYS < <(jq -r '(.sshPubKeys // [])[]' "$CONFIG_FILE")
              if [[ "''${#SSH_PUBKEYS[@]}" -eq 0 ]]; then
                  ssh_pubkey=$(json_string '.sshPubKey' "")
                  [[ -z "$ssh_pubkey" ]] || SSH_PUBKEYS+=("$ssh_pubkey")
              fi
          fi
          if [[ "''${#SSH_PUBKEYS[@]}" -eq 0 ]]; then
              SSH_PUBKEYS+=("$HOME/.ssh/id_ed25519.pub")
          fi
      }

      load_config
      export KUBECONFIG

      ${builtins.readFile ./dev-machine-body.sh}
    '';
  }
