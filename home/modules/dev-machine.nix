# Phase 3 — devpod wiring + operator scripting for the locked-down LLM dev
# machines (llm-notes/wip/ai-dev-machine-kubevirt-plan.md).
#
# These wrappers live ONLY on the operator's workstation — deliberately NOT in
# the VM/devcontainer image and NOT a top-level repo Justfile. devpod/virtctl/
# kubectl and the whole orchestration stay off the PATH *inside* the sandbox, so
# an agent in a dev machine can't see devpod, recursively spawn sandboxes, or
# reach the cluster. That is the core lockdown intent.
#
# Shape (plan "Start" path — SSH provider to a VM we create; a thin custom
# KubeVirt devpod provider is the documented graduation, only if the manual
# lifecycle ergonomics bite):
#
#   dev-machine up <repo>   creates a KubeVirt VirtualMachine from the thin base
#                           containerDisk (Phase 1.3), injects the operator's SSH
#                           pubkey via the guest agent, tunnels to its sshd with
#                           `virtctl port-forward`, points a per-machine devpod
#                           ssh provider at 127.0.0.1:<port>, and `devpod up`s the
#                           repo's devcontainer.json inside the VM.
#   dev-machine ssh  <name> drop into the running devcontainer (`devpod ssh`).
#   dev-machine list        VMs + devpod workspaces.
#   dev-machine down <name> tear the workspace + VM + secret + tunnel down.
#   dev-machine publish-base (re)build + push the thin base containerDisk to creil
#                           (a prerequisite for `up`; run once / on base bumps).
#
# IMAGE FRESHNESS (workaround until CI lands, plan Phase 3): `up` rebuilds + pushes
# the Phase-2.2 dev image to creil by default so every session starts on a current
# claude-code (cheap — claude comes prebuilt from numtide's cache, so it's a
# cache-pull + push, not a real build). `--no-rebuild` skips it for fast iteration.
#
# Auth: everything drives the cluster with the operator's Authelia OIDC identity
# via the standalone kubeconfig from kube.nix (KUBECONFIG exported below). Pushing
# images needs a one-time `skopeo login forgejo.internal` on the workstation.
{
  config,
  pkgs,
  lib,
  ...
}: let
  # Dedicated namespace — Phase 5 hangs a default-deny-egress NetworkPolicy off
  # this same namespace; `up` creates it plainly for now.
  namespace = "dev-machines";

  # creil (Forgejo) registry holding both the base containerDisk and the dev image.
  registry = "forgejo.internal/mutantmell";
  registryHost = builtins.head (lib.splitString "/" registry);
  baseImage = "${registry}/dev-machine-base:latest";
  devImage = "${registry}/dev-machine-dev:latest";

  # The dotfiles flake the images are built from (operator workstation checkout).
  flake = "${config.home.homeDirectory}/git/dotfiles";

  # Standalone OIDC kubeconfig from kube.nix (kept out of ~/.kube/config on purpose).
  kubeconfig = "${config.home.homeDirectory}/.kube/erebonia-oidc.yaml";

  # Pubkey the guest agent injects into the VM's `dev` user (AccessCredentials).
  sshPubKey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";

  defaultMemory = "8Gi";
  defaultCpu = "4";

  # The dev-machine VirtualMachine, authored as a Nix attrset (the repo idiom —
  # cf. kubevirt.nix's KubeVirt CR) and rendered to a guaranteed-valid JSON store
  # file, rather than string-interpolated YAML inside the wrapper. The wrapper
  # `jq`-patches the few per-session fields (name, secret, cpu, memory) and
  # `kubectl apply`s it imperatively — the VM is ephemeral/per-session, so it is
  # deliberately NOT a committed services.k3s.manifests resource. Static bits live
  # here; the `PLACEHOLDER`s are overwritten at apply time.
  #
  # cpu.model host-passthrough surfaces the host vmx flag into the guest, so the
  # regular NixOS kernel inside gets /dev/kvm and this flake's nixosTests run
  # nested (erebonia's host is kvm_intel nested=1). masquerade binding puts the VM
  # behind the virt-launcher pod IP for the Phase 5 NetworkPolicy.
  vmManifest = pkgs.writeText "dev-machine-vm.json" (builtins.toJSON {
    apiVersion = "kubevirt.io/v1";
    kind = "VirtualMachine";
    metadata = {
      name = "PLACEHOLDER";
      namespace = namespace;
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
            resources.requests.memory = "8Gi";
            devices = {
              disks = [
                {
                  name = "rootdisk";
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
              containerDisk.image = baseImage;
            }
          ];
        };
      };
    };
  });

  dev-machine = pkgs.writeShellApplication {
    name = "dev-machine";
    runtimeInputs = with pkgs; [
      kubectl # cluster CRUD (VM, secret, namespace) + OIDC login trigger
      kubevirt # provides virtctl (port-forward tunnel to the VM sshd)
      devpod # builds/runs the devcontainer.json inside the VM over SSH
      skopeo # push the Nix-built images to creil
      openssh # sshd readiness probe before handing off to devpod
      jq # patch the per-session fields into the VM manifest skeleton
      coreutils
      gnused
      gawk
    ];
    text = ''
      export KUBECONFIG="${kubeconfig}"
      NAMESPACE="${namespace}"
      BASE_IMAGE="${baseImage}"
      DEV_IMAGE="${devImage}"
      REGISTRY_HOST="${registryHost}"
      FLAKE="${flake}"
      SSH_PUBKEY="${sshPubKey}"
      DEFAULT_MEMORY="${defaultMemory}"
      DEFAULT_CPU="${defaultCpu}"
      VM_MANIFEST="${vmManifest}"
      STATE="''${XDG_STATE_HOME:-$HOME/.local/state}/dev-machine"

      # DNS-1123-safe machine name derived from a repo/path basename.
      sanitize() {
          echo "$1" | tr '[:upper:]' '[:lower:]' \
              | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40
      }

      # Deterministic local forward port per machine (few machines, single user —
      # collisions are not a real concern, and a stable port survives `ssh` after
      # the shell that ran `up` is gone).
      port_for() {
          local sum
          sum=$(echo -n "$1" | cksum | awk '{print $1}')
          echo $(( 18000 + (sum % 1000) ))
      }

      # Start (or revive) the virtctl port-forward backing 127.0.0.1:<port> -> VM:22.
      # nohup'd so it outlives the `up`/`ssh` invocation for the session's life.
      ensure_portforward() {
          local name=$1 port=$2 statedir=$3
          local pidfile="$statedir/portforward.pid"
          if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
              return 0
          fi
          mkdir -p "$statedir"
          nohup virtctl port-forward "vmi/dm-$name" -n "$NAMESPACE" "$port:22" \
              >"$statedir/portforward.log" 2>&1 &
          echo $! >"$pidfile"
          sleep 1
      }

      # Pushing/inspecting images on creil needs a one-time `skopeo login`; the
      # credential is durable workstation state (auth.json), not a per-session
      # thing this tool owns. Fail fast with the exact command instead of letting
      # a raw registry-auth error surface mid-`up`.
      require_login() {
          if ! skopeo login --get-login "$REGISTRY_HOST" >/dev/null 2>&1; then
              echo "not logged in to $REGISTRY_HOST." >&2
              echo "run:  skopeo login $REGISTRY_HOST" >&2
              return 1
          fi
      }

      build_and_push() {
          local attr=$1 ref=$2 stream
          echo "==> building $attr"
          stream=$(nix build --no-link --print-out-paths "$FLAKE#$attr")
          echo "==> pushing $ref"
          "$stream" | skopeo copy docker-archive:/dev/stdin "docker://$ref"
      }

      create_vm() {
          local name=$1 memory=$2 cpu=$3
          local vm="dm-$name" secret="dm-$name-ssh-key"

          [[ -f "$SSH_PUBKEY" ]] || {
              echo "missing SSH pubkey: $SSH_PUBKEY" >&2
              return 1
          }

          kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
              || kubectl create namespace "$NAMESPACE"

          # The pubkey secret KubeVirt's AccessCredentials reads; apply-style so a
          # re-`up` of the same name refreshes it.
          kubectl create secret generic "$secret" -n "$NAMESPACE" \
              --from-file=key="$SSH_PUBKEY" --dry-run=client -o yaml \
              | kubectl apply -f -

          # Patch the per-session fields into the Nix-authored skeleton (valid JSON
          # by construction) and apply. --argjson keeps cores an integer.
          jq \
              --arg vm "$vm" \
              --arg name "$name" \
              --arg secret "$secret" \
              --arg memory "$memory" \
              --argjson cpu "$cpu" \
              '.metadata.name = $vm
               | .spec.template.metadata.labels."dev-machine" = $name
               | .spec.template.spec.domain.cpu.cores = $cpu
               | .spec.template.spec.domain.resources.requests.memory = $memory
               | .spec.template.spec.accessCredentials[0].sshPublicKey.source.secret.secretName = $secret' \
              "$VM_MANIFEST" \
              | kubectl apply -f -
      }

      cmd_up() {
          local source="" name="" rebuild=1 memory cpu
          memory="$DEFAULT_MEMORY"
          cpu="$DEFAULT_CPU"
          while [[ $# -gt 0 ]]; do
              case "$1" in
                  --no-rebuild) rebuild=0; shift ;;
                  --name) name="$2"; shift 2 ;;
                  --memory) memory="$2"; shift 2 ;;
                  --cpu) cpu="$2"; shift 2 ;;
                  -*) echo "unknown flag: $1" >&2; return 1 ;;
                  *)
                      if [[ -z "$source" ]]; then
                          source="$1"
                      else
                          echo "unexpected arg: $1" >&2
                          return 1
                      fi
                      shift
                      ;;
              esac
          done
          [[ -n "$source" ]] || {
              echo "usage: dev-machine up <repo-url-or-path> [--name N] [--no-rebuild] [--memory 8Gi] [--cpu 4]" >&2
              return 1
          }
          if [[ -z "$name" ]]; then
              name=$(basename "$source")
              name="''${name%.git}"
          fi
          name=$(sanitize "$name")
          local vm="dm-$name" provider="dm-$name" port statedir
          port=$(port_for "$name")
          statedir="$STATE/$name"

          # Trigger OIDC login (interactive) up front so the backgrounded virtctl
          # later reuses the cached token instead of stalling on a browser prompt.
          kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || true

          # Anything that touches creil (the rebuild push, the base presence check,
          # the base publish) needs the registry login — check once, up front.
          require_login

          if [[ "$rebuild" -eq 1 ]]; then
              build_and_push dev-machine-dev-image "$DEV_IMAGE"
          fi

          # The VM boots from the base containerDisk; publish it on demand if it's
          # not in the registry yet (first use, or it was GC'd). The base changes
          # rarely and KubeVirt caches it, so this only fires when actually absent —
          # use `dev-machine publish-base` to force a re-push after a base bump.
          if ! skopeo inspect "docker://$BASE_IMAGE" >/dev/null 2>&1; then
              echo "==> base image $BASE_IMAGE not in registry; building + pushing it"
              build_and_push dev-machine-image "$BASE_IMAGE"
          fi

          echo "==> creating VM $vm"
          create_vm "$name" "$memory" "$cpu"

          echo "==> waiting for VM to be ready"
          kubectl wait "vm/$vm" -n "$NAMESPACE" --for=condition=Ready --timeout=300s
          echo "==> waiting for guest agent (ssh key injection)"
          kubectl wait "vmi/$vm" -n "$NAMESPACE" --for=condition=AgentConnected --timeout=180s

          mkdir -p "$statedir"
          echo "$port" >"$statedir/port"
          ensure_portforward "$name" "$port" "$statedir"

          echo "==> waiting for sshd"
          local ready=0
          for _ in $(seq 1 30); do
              if ssh -p "$port" -o StrictHostKeyChecking=no \
                  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 \
                  -o BatchMode=yes dev@127.0.0.1 true 2>/dev/null; then
                  ready=1
                  break
              fi
              sleep 2
          done
          [[ "$ready" -eq 1 ]] || {
              echo "VM sshd did not come up; check $statedir/portforward.log" >&2
              return 1
          }

          # Per-machine ssh provider pinned to this VM's tunnel. Built-in ssh is off
          # so EXTRA_FLAGS' host-key relaxation applies — these VMs are ephemeral and
          # reuse 127.0.0.1:<port>, so a pinned known_hosts entry only gets in the way.
          devpod provider delete "$provider" 2>/dev/null || true
          devpod provider add ssh --name "$provider" --use \
              -o HOST="dev@127.0.0.1" \
              -o PORT="$port" \
              -o USE_BUILTIN_SSH=false \
              -o EXTRA_FLAGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

          echo "==> bringing the workspace up (devcontainer.json inside the VM)"
          devpod up "$source" --id "$name" --provider "$provider" --ide none

          echo
          echo "dev machine '$name' is up. Connect with:  dev-machine ssh $name"
      }

      cmd_ssh() {
          local name
          name=$(sanitize "''${1:-}")
          [[ -n "$name" ]] || { echo "usage: dev-machine ssh <name>" >&2; return 1; }
          local statedir="$STATE/$name"
          [[ -d "$statedir" ]] || { echo "no such dev machine: $name" >&2; return 1; }
          ensure_portforward "$name" "$(cat "$statedir/port")" "$statedir"
          devpod ssh "$name"
      }

      cmd_list() {
          echo "VMs:"
          kubectl get vm -n "$NAMESPACE" 2>/dev/null || true
          echo
          echo "Workspaces:"
          devpod list
      }

      cmd_down() {
          local name
          name=$(sanitize "''${1:-}")
          [[ -n "$name" ]] || { echo "usage: dev-machine down <name>" >&2; return 1; }
          echo "==> tearing down $name"
          devpod delete "$name" --force 2>/dev/null || true
          devpod provider delete "dm-$name" 2>/dev/null || true
          kubectl delete vm "dm-$name" -n "$NAMESPACE" --ignore-not-found
          kubectl delete secret "dm-$name-ssh-key" -n "$NAMESPACE" --ignore-not-found
          local statedir="$STATE/$name"
          if [[ -f "$statedir/portforward.pid" ]]; then
              kill "$(cat "$statedir/portforward.pid")" 2>/dev/null || true
          fi
          rm -rf "$statedir"
      }

      cmd_publish_base() {
          require_login
          build_and_push dev-machine-image "$BASE_IMAGE"
      }

      usage() {
          cat >&2 <<'USAGE'
      dev-machine — locked-down LLM dev machines on KubeVirt

        dev-machine up <repo> [--name N] [--no-rebuild] [--memory 8Gi] [--cpu 4]
        dev-machine ssh <name>
        dev-machine list
        dev-machine down <name>
        dev-machine publish-base
      USAGE
      }

      cmd="''${1:-}"
      [[ $# -gt 0 ]] && shift || true
      case "$cmd" in
          up) cmd_up "$@" ;;
          ssh) cmd_ssh "$@" ;;
          list | ls) cmd_list "$@" ;;
          down | rm) cmd_down "$@" ;;
          publish-base) cmd_publish_base "$@" ;;
          "" | -h | --help | help) usage ;;
          *) echo "unknown command: $cmd" >&2; usage; exit 1 ;;
      esac
    '';
  };
in {
  home.packages = [dev-machine];
}
