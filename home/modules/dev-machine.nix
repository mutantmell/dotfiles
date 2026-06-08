# Phase 3 + Phase 4 — devpod wiring, operator scripting, and the scoped git-push
# credential for the locked-down LLM dev machines
# (llm-notes/wip/ai-dev-machine-kubevirt-plan.md).
#
# Shipped as a home-manager integration: `programs.dev-machine.enable` (plus a
# few config knobs) installs a single `dev-machine` wrapper on the operator's
# workstation. The wrapper lives ONLY here — deliberately NOT in the
# VM/devcontainer image and NOT a top-level repo Justfile. devpod/virtctl/kubectl
# and the whole orchestration stay off the PATH *inside* the sandbox, so an agent
# in a dev machine can't see devpod, recursively spawn sandboxes, or reach the
# cluster. That is the core lockdown intent.
#
# Shape (plan "Start" path — SSH provider to a VM we create; a thin custom
# KubeVirt devpod provider is the documented graduation, only if the manual
# lifecycle ergonomics bite):
#
#   dev-machine up <repo>   creates a KubeVirt VirtualMachine from the thin base
#                           containerDisk (Phase 1.3), injects the operator's SSH
#                           pubkey(s) via the guest agent (Phase 6: `sshPubKeys`
#                           may carry several — operator + mobile — so a phone can
#                           mosh in alongside the workstation), tunnels to its sshd with
#                           `virtctl port-forward`, points a per-machine devpod
#                           ssh provider at 127.0.0.1:<port>, and `devpod up`s the
#                           repo's devcontainer.json inside the VM. For a creil
#                           repo it then mints a per-session SSH key on the `cc`
#                           bot account (Forgejo API) and injects it as the
#                           sandbox's ONLY git-push credential — pushes go out as
#                           `cc` (Phase 4).
#   dev-machine ssh  <name> drop into the running devcontainer (`devpod ssh`).
#                           `--recover` restarts a dead in-VM agent/container
#                           (`devpod up`) first — for a VM that crashed + rebooted.
#   dev-machine list        VMs + devpod workspaces.
#   dev-machine rescue <name> best-effort RECOVERY of a wedged-but-alive VM back
#                           to a working devcontainer (guest-side OOM reaped the
#                           agent/container but the OOM-protected sshd survived):
#                           takes a safety backup of the working tree (git bundle +
#                           patch + untracked, to $STATE/<name>/rescue/), then
#                           `devpod up`s the session back. `--no-revive` backs up
#                           only. Non-destructive. Detects + reports when the VMI was
#                           pod-restarted (emptyDisk scratch wiped — machine
#                           rebuildable, work gone); durable fix is a persistent-
#                           scratch PVC, deferred until iSCSI lands.
#   dev-machine down <name> tear the workspace + VM + secret + tunnel down, and
#                           revoke the cc SSH key. `--no-agent` skips the in-VM
#                           devpod teardown when the VM is crashed/OOM-killed (the
#                           normal teardown blocks on the dead agent tunnel).
#   dev-machine publish-base (re)build + push the thin base containerDisk to creil
#                           (a prerequisite for `up`; run once / on base bumps).
#
# IMAGE FRESHNESS (workaround until CI lands, plan Phase 3): `up` rebuilds + pushes
# the Phase-2.2 dev image to creil by default so every session starts on a current
# claude-code (cheap — claude comes prebuilt from numtide's cache, so it's a
# cache-pull + push, not a real build). `--no-rebuild` skips it for fast iteration.
#
# PUSH CREDENTIAL (Phase 4): the sandbox holds EXACTLY ONE credential and it is
# NOT the operator identity — it is the **`cc` bot user**. `up` generates a fresh
# ed25519 keypair per session and registers the public half as an **SSH key on the
# cc account** (Forgejo `POST /user/keys`, authed with cc's own token — read from
# the file at `forgejoTokenFile`, a sops-decrypted tmpfs path that never enters the
# sandbox), then injects the private half into the devcontainer with git pinned to
# push forgejo over SSH. Pushes therefore authenticate **as cc**, so the blast
# radius is whatever cc can write to — keep cc's repo access scoped to bound it.
# `down` deletes the key. devpod's own host-credential forwarding is disabled on
# the ssh path (`--start-services=false`) so the operator's git/docker creds are
# never proxied into the session — the cc key is the only push path. Branch
# protection on creil (push feature branches, no direct protected-main merge) is
# the complementary server-side control; configure it once per repo in Forgejo.
# NOTE: the SSH push path makes forgejo SSH (:22) a required egress for the
# not-yet-landed Phase 5 NetworkPolicy.
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
  cfg = config.programs.dev-machine;

  # creil (Forgejo) registry holding both the base containerDisk and the dev image.
  registryHost = builtins.head (lib.splitString "/" cfg.registry);
  baseImage = "${cfg.registry}/dev-machine-base:latest";
  devImage = "${cfg.registry}/dev-machine-dev:latest";

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
      inherit (cfg) namespace;
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
                {
                  name = "scratch";
                  # serial → /dev/disk/by-id/virtio-scratch in the guest, which the
                  # base image autoFormats + mounts at /var/lib/docker.
                  serial = "scratch";
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
              # Always re-pull the base :latest so a freshly `publish-base`d image
              # is picked up — otherwise the node can boot a cached older layer.
              containerDisk = {
                image = baseImage;
                imagePullPolicy = "Always";
              };
            }
            {
              name = "scratch";
              # Ephemeral runtime scratch for docker data-root (dev image +
              # in-container builds). Dies with the VM (no CSI); the base image
              # formats + mounts it at /var/lib/docker.
              emptyDisk.capacity = "60Gi";
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
      openssh # sshd readiness probe + ssh-keygen for the per-session deploy key
      curl # Forgejo API (mint/revoke the deploy key)
      git # read a local checkout's origin to resolve its creil owner/repo
      jq # patch the per-session fields into the VM manifest skeleton
      coreutils
      gnused
      gawk
    ];
    text = ''
      export KUBECONFIG="${cfg.kubeconfig}"
      NAMESPACE="${cfg.namespace}"
      BASE_IMAGE="${baseImage}"
      DEV_IMAGE="${devImage}"
      REGISTRY_HOST="${registryHost}"
      FLAKE="${cfg.flake}"
      # Phase 6: ALL operator pubkeys the guest agent should inject into `dev`'s
      # authorized_keys (operator workstation + mobile, etc.), as a bash array of
      # paths rendered from cfg.sshPubKeys (each path Nix-quoted so spaces survive).
      # Multiple keys let a mobile operator attach WITHOUT an image rebuild — the
      # AccessCredentials secret carries every line and KubeVirt appends each.
      SSH_PUBKEYS=(${lib.concatMapStringsSep " " (p: "\"${p}\"") cfg.sshPubKeys})
      DEFAULT_MEMORY="${cfg.defaultMemory}"
      DEFAULT_CPU="${cfg.defaultCpu}"
      DEFAULT_DISK="${cfg.defaultDisk}"
      VM_MANIFEST="${vmManifest}"
      FORGEJO_API="${cfg.forgejoApi}"
      FORGEJO_USER="${cfg.forgejoUser}"
      FORGEJO_SSH_USER="${cfg.forgejoSshUser}"
      FORGEJO_TOKEN_FILE="${cfg.forgejoTokenFile}"
      CACERT="${cfg.caCert}"
      COMMIT_NAME="${cfg.commitName}"
      COMMIT_EMAIL="${cfg.commitEmail}"
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

      # Start (or revive) the port-forward backing 127.0.0.1:<port> -> VM:22.
      # We forward to the VM's virt-launcher POD (kubectl port-forward), NOT via
      # `virtctl port-forward vmi/...`: masquerade DNATs the pod's :22 to the guest
      # sshd, whereas the vmi path mis-dials the guest here — the guest's docker0
      # (172.17.0.1) and the reported pod IP shadow the masquerade 10.0.2.2, so it
      # refused with an empty-host `dial tcp :22`. nohup'd so the tunnel outlives the
      # `up`/`ssh` invocation for the session's life.
      ensure_portforward() {
          local name=$1 port=$2 statedir=$3
          local pidfile="$statedir/portforward.pid"
          if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
              return 0
          fi
          mkdir -p "$statedir"
          # Resolve the active virt-launcher pod via the VMI uid (the canonical
          # kubevirt.io/created-by label — the pod is NOT labelled by domain name).
          local uid pod
          uid=$(kubectl get vmi "dm-$name" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null)
          [[ -n "$uid" ]] || {
              echo "VMI dm-$name not found" >&2
              return 1
          }
          pod=$(kubectl get pods -n "$NAMESPACE" \
              -l kubevirt.io/created-by="$uid" \
              --field-selector=status.phase=Running \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
          [[ -n "$pod" ]] || {
              echo "no running virt-launcher pod for dm-$name" >&2
              return 1
          }
          nohup kubectl port-forward "pod/$pod" -n "$NAMESPACE" "$port:22" \
              >"$statedir/portforward.log" 2>&1 &
          echo $! >"$pidfile"
          sleep 1
      }

      # Force the interactive OIDC token mint up front, with stderr VISIBLE. The
      # OIDC kubeconfig authenticates via an exec plugin (kubectl-oidc_login,
      # authcode-keyboard): when the cached token has lapsed it prints an Authelia
      # URL and waits on stdin for the pasted code. That prompt rides kubectl's
      # stderr, so any cluster call that suppresses stderr (e.g. cmd_list's
      # `get vm 2>/dev/null`) or runs backgrounded (the port-forward) silently
      # dead-hangs waiting for a code the operator never sees. Run one cheap,
      # foreground, stderr-visible call here first, so an expired session surfaces
      # the prompt before the real work and every later call reuses the warm token.
      # `version` contacts the apiserver (which runs the exec plugin) but needs no
      # RBAC. Call it at the top of every cluster-touching command.
      dm_login() {
          if ! kubectl version >/dev/null; then
              echo "cluster OIDC login failed; complete the Authelia prompt and retry" >&2
              return 1
          fi
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

      # ── Phase 4: per-session scoped git-push key on the cc bot account ──────
      # The cc bot's Forgejo token lives in a sops-decrypted tmpfs file
      # (forgejoTokenFile); read it on demand. It is used ONLY to add/remove cc's
      # own SSH keys (POST/DELETE /user/keys) and never enters the VM/sandbox.
      forgejo_token() {
          if [[ -z "$FORGEJO_TOKEN_FILE" || ! -f "$FORGEJO_TOKEN_FILE" ]]; then
              echo "Forgejo token unavailable (programs.dev-machine.forgejoTokenFile)." >&2
              echo "add 'dev-machine-forgejo-token' to the edith sops secrets and" >&2
              echo "re-run home-manager switch, or pass --no-push-cred." >&2
              return 1
          fi
          cat "$FORGEJO_TOKEN_FILE"
      }

      # curl against the Forgejo API, trusting the internal CA when configured.
      curl_fj() {
          local args=(-fsS)
          [[ -n "$CACERT" ]] && args+=(--cacert "$CACERT")
          curl "''${args[@]}" "$@"
      }

      # Map a workspace source (creil URL or local checkout's origin) to its
      # forgejo owner/repo; empty for non-creil sources (which get no push cred).
      # Used only to gate provisioning + for messaging — the cc key is account-
      # level, so the push works for any repo cc can write to.
      parse_repo() {
          local src=$1 url rr
          if [[ -d "$src" ]]; then
              url=$(git -C "$src" remote get-url origin 2>/dev/null) || return 0
          else
              url=$src
          fi
          case "$url" in
              *forgejo.internal*) : ;;
              *) return 0 ;;
          esac
          rr=$(echo "$url" | sed -E 's#.*forgejo\.internal[:/]+##; s#/+$##; s#\.git$##')
          if [[ "$rr" =~ ^[^/]+/[^/]+$ ]]; then echo "$rr"; fi
      }

      # Delete any of cc's SSH keys whose title matches (idempotent re-up).
      delete_keys_by_title() {
          local title=$1 token=$2
          curl_fj -H "Authorization: token $token" "$FORGEJO_API/user/keys" 2>/dev/null \
              | jq -r --arg t "$title" '.[] | select(.title==$t) | .id' \
              | while read -r kid; do
                  curl_fj -X DELETE -H "Authorization: token $token" \
                      "$FORGEJO_API/user/keys/$kid" >/dev/null 2>&1 || true
                done
      }

      # Generate a fresh per-session keypair, register the pubkey as an SSH key on
      # the cc bot account, record the key id for revoke, and inject the private
      # key into the devcontainer. $3 = token.
      provision_push_cred() {
          local name=$1 statedir=$2 token=$3
          local keyfile title pub resp id
          keyfile="$statedir/deploy_key"
          title="dev-machine-$name"
          mkdir -p "$statedir"
          rm -f "$keyfile" "$keyfile.pub"
          ssh-keygen -t ed25519 -N "" -C "$title" -f "$keyfile" >/dev/null
          delete_keys_by_title "$title" "$token" || true
          pub=$(cat "$keyfile.pub")
          resp=$(curl_fj -X POST -H "Authorization: token $token" \
              -H "Content-Type: application/json" \
              "$FORGEJO_API/user/keys" \
              -d "$(jq -n --arg t "$title" --arg k "$pub" \
                    '{title:$t, key:$k}')") || {
              echo "failed to register SSH key on the $FORGEJO_USER account" >&2
              return 1
          }
          id=$(echo "$resp" | jq -r '.id')
          printf '%s\n' "$id" >"$statedir/deploy_key_id"
          inject_deploy_key "$name" "$keyfile"
      }

      # Push the private key + git config into the running devcontainer in a SINGLE
      # one-shot exec (start-services + agent-forwarding off, so devpod forwards
      # NONE of the operator's git/docker creds or SSH agent). The key is base64'd
      # INTO the command rather
      # than streamed over stdin — `devpod ssh --command` does not reliably forward
      # stdin, and the key is legitimately the sandbox's own, so inline is fine.
      # Pins forgejo to SSH so pushes use ONLY this cc key (authenticating as cc),
      # and sets the cc commit identity.
      inject_deploy_key() {
          local name=$1 keyfile=$2 b64
          b64=$(base64 -w0 "$keyfile")
          devpod ssh "$name" --start-services=false --agent-forwarding=false --command "
              set -e
              umask 077
              mkdir -p ~/.ssh
              printf %s '$b64' | base64 -d > ~/.ssh/dm_deploy_key
              chmod 600 ~/.ssh/dm_deploy_key
              { echo 'Host forgejo.internal'
                echo '  User $FORGEJO_SSH_USER'
                echo '  IdentityFile ~/.ssh/dm_deploy_key'
                echo '  IdentitiesOnly yes'
                echo '  StrictHostKeyChecking accept-new'
              } > ~/.ssh/config
              chmod 600 ~/.ssh/config
              git config --global url.'$FORGEJO_SSH_USER@forgejo.internal:'.insteadOf 'https://forgejo.internal/'
              git config --global user.name '$COMMIT_NAME'
              git config --global user.email '$COMMIT_EMAIL'
          "
      }

      # Revoke a previously-minted cc SSH key (recorded in the state dir). $2=token.
      revoke_push_cred() {
          local statedir=$1 token=$2 id
          [[ -f "$statedir/deploy_key_id" ]] || return 0
          id=$(cat "$statedir/deploy_key_id")
          curl_fj -X DELETE -H "Authorization: token $token" \
              "$FORGEJO_API/user/keys/$id" >/dev/null 2>&1 || true
      }

      # ── rescue: extract uncommitted work from a still-alive dev machine ────────
      # The in-container extraction script, delivered either through the VM's sshd
      # + docker (extract_via_docker) or through devpod (extract_via_devpod). It
      # finds the git workspace under /workspaces, packs a bundle of ALL refs (so
      # committed-but-unpushed history survives), a working-tree patch, the git
      # status, and the NON-IGNORED untracked files into one tarball, then base64s
      # it to stdout. Untracked uses --exclude-standard so build junk on scratch
      # (the nixosTest images, docker layers) is skipped. Deliberately contains NO
      # single quotes, so it survives being passed as a devpod `--command` string.
      extract_script() {
          # Built with printf (not a heredoc) on purpose: a second here-doc
          # inside this Nix indented string fights the indentation-strip the
          # usage() here-doc relies on. Each line is a single-quoted arg, so
          # nothing here is expanded locally — it all runs in the container/VM.
          # shellcheck disable=SC2016
          printf '%s\n' \
              'set -e' \
              'ws=' \
              'for d in /workspaces/*; do' \
              '  if [ -d "$d/.git" ]; then ws=$d; break; fi' \
              'done' \
              'if [ -z "$ws" ]; then echo "no git workspace under /workspaces" >&2; exit 3; fi' \
              'cd "$ws"' \
              'tmp=$(mktemp -d)' \
              'printf %s "$ws" > "$tmp/workspace_path"' \
              'git bundle create "$tmp/rescue.bundle" --all >/dev/null 2>&1 || true' \
              'git diff HEAD > "$tmp/working.patch" 2>/dev/null || true' \
              'git status --porcelain=v1 > "$tmp/git-status.txt" 2>/dev/null || true' \
              'git ls-files --others --exclude-standard -z 2>/dev/null | tar --null --no-recursion -czf "$tmp/untracked.tar.gz" --files-from=- 2>/dev/null || true' \
              'tar -C "$tmp" -czf - . | base64' \
              'rm -rf "$tmp"'
      }

      # Raw VM ssh + docker exec: find the running devcontainer (the one with a
      # /workspaces/*/.git) and run the extraction inside it, script on stdin to
      # `sh -s` (no quoting to get wrong). The most robust path — it never touches
      # devpod's (observed-fragile) tunnel, only the OOM-protected VM sshd.
      extract_via_docker() {
          local port=$1 cid
          cid=$(ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=5 -o BatchMode=yes dev@127.0.0.1 \
              'for c in $(docker ps -q); do if docker exec "$c" sh -c "ls -d /workspaces/*/.git" >/dev/null 2>&1; then echo "$c"; break; fi; done' \
              2>/dev/null)
          [[ -n "$cid" ]] || {
              echo "no running devcontainer with a /workspaces git repo found" >&2
              return 1
          }
          extract_script | ssh -p "$port" -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes \
              dev@127.0.0.1 "docker exec -i $cid sh -s"
      }

      # Fallback: deliver the same script through devpod's in-container shell. Used
      # only when the docker path finds nothing — e.g. the container is stopped and
      # the revive brought it back under devpod but a plain `docker ps` raced it.
      extract_via_devpod() {
          local name=$1 script
          script=$(extract_script)
          devpod ssh "$name" --start-services=false --agent-forwarding=false \
              --command "$script"
      }

      # Capture the workspace (git bundle of all refs + working-tree patch +
      # non-ignored untracked files) from the live VM into $rescuedir, unpacked.
      # Tries the robust raw-docker path first, then devpod. Returns 0 only when
      # a non-empty payload was unpacked. This is the INSURANCE taken around a
      # recovery attempt — never the end goal on its own. $rescuedir must exist.
      rescue_backup() {
          local name=$1 port=$2 rescuedir=$3 out=""
          out=$(extract_via_docker "$port" 2>>"$rescuedir/extract.log") || out=""
          if [[ -z "$out" ]]; then
              out=$(extract_via_devpod "$name" 2>>"$rescuedir/extract.log") || out=""
          fi
          [[ -n "$out" ]] || return 1
          if ! printf '%s' "$out" | base64 -d >"$rescuedir/rescue.tar.gz" 2>/dev/null; then
              printf '%s' "$out" >"$rescuedir/rescue.b64"
              return 1
          fi
          tar -C "$rescuedir" -xzf "$rescuedir/rescue.tar.gz" && rm -f "$rescuedir/rescue.tar.gz"
      }

      # How to graft a rescued backup back onto a fresh checkout of the repo.
      rescue_print_reapply() {
          local rescuedir=$1
          [[ -f "$rescuedir/workspace_path" ]] && echo "  (workspace was: $(cat "$rescuedir/workspace_path"))"
          echo "  re-apply into a fresh checkout of the repo:"
          echo "    git fetch \"$rescuedir/rescue.bundle\" \"+refs/heads/*:refs/heads/rescue/*\"  # recover commits"
          echo "    git apply \"$rescuedir/working.patch\"   # restore dirty tracked files"
          echo "    tar -C . -xzf \"$rescuedir/untracked.tar.gz\"   # restore untracked files"
      }

      create_vm() {
          local name=$1 memory=$2 cpu=$3 disk=$4
          local vm="dm-$name" secret="dm-$name-ssh-key"

          [[ "''${#SSH_PUBKEYS[@]}" -gt 0 ]] || {
              echo "no SSH pubkeys configured (programs.dev-machine.sshPubKeys)" >&2
              return 1
          }
          local k
          for k in "''${SSH_PUBKEYS[@]}"; do
              [[ -f "$k" ]] || {
                  echo "missing SSH pubkey: $k" >&2
                  return 1
              }
          done

          kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
              || kubectl create namespace "$NAMESPACE"

          # The pubkey secret KubeVirt's AccessCredentials reads; apply-style so a
          # re-`up` of the same name refreshes it. Phase 6: concatenate ALL the
          # configured pubkeys into one authorized_keys blob — KubeVirt's guest
          # agent appends each line, so every listed key (operator + mobile) gets
          # injected into `dev`'s authorized_keys. cat preserves each file's
          # trailing newline so the lines don't merge.
          local blob
          blob=$(mktemp)
          # shellcheck disable=SC2064
          trap "rm -f '$blob'" RETURN
          cat "''${SSH_PUBKEYS[@]}" >"$blob"
          kubectl create secret generic "$secret" -n "$NAMESPACE" \
              --from-file=key="$blob" --dry-run=client -o yaml \
              | kubectl apply -f -

          # Patch the per-session fields into the Nix-authored skeleton (valid JSON
          # by construction) and apply. --argjson keeps cores an integer.
          jq \
              --arg vm "$vm" \
              --arg name "$name" \
              --arg secret "$secret" \
              --arg memory "$memory" \
              --argjson cpu "$cpu" \
              --arg disk "$disk" \
              '.metadata.name = $vm
               | .spec.template.metadata.labels."dev-machine" = $name
               | .spec.template.spec.domain.cpu.cores = $cpu
               | .spec.template.spec.domain.resources.requests.memory = $memory
               | (.spec.template.spec.volumes[] | select(.name == "scratch").emptyDisk.capacity) = $disk
               | .spec.template.spec.accessCredentials[0].sshPublicKey.source.secret.secretName = $secret' \
              "$VM_MANIFEST" \
              | kubectl apply -f -
      }

      cmd_up() {
          local source="" name="" rebuild=1 memory cpu disk repo="" push_cred=1
          memory="$DEFAULT_MEMORY"
          cpu="$DEFAULT_CPU"
          disk="$DEFAULT_DISK"
          while [[ $# -gt 0 ]]; do
              case "$1" in
                  --no-rebuild) rebuild=0; shift ;;
                  --no-push-cred) push_cred=0; shift ;;
                  --name) name="$2"; shift 2 ;;
                  --repo) repo="$2"; shift 2 ;;
                  --memory) memory="$2"; shift 2 ;;
                  --cpu) cpu="$2"; shift 2 ;;
                  --disk) disk="$2"; shift 2 ;;
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
          # No source given: resolve the current checkout's `origin` URL and use
          # THAT — identical to passing the URL by hand (devpod clones the default
          # branch in the VM), not the local working tree. We only translate "here"
          # into the equivalent remote URL; the branch/commit is whatever a fresh
          # clone gets. A CWD with no origin remote is a usage error.
          if [[ -z "$source" ]]; then
              if source=$(git -C "$PWD" remote get-url origin 2>/dev/null) && [[ -n "$source" ]]; then
                  echo "==> no repo given; using current checkout's origin: $source" >&2
              else
                  echo "usage: dev-machine up [<repo-url-or-path>] [--name N] [--repo owner/name] [--no-rebuild] [--no-push-cred] [--memory 8Gi] [--cpu 4] [--disk 60Gi]" >&2
                  echo "       (omit the repo to use the current directory's origin remote URL)" >&2
                  return 1
              fi
          fi
          if [[ -z "$name" ]]; then
              name=$(basename "$source")
              name="''${name%.git}"
          fi
          name=$(sanitize "$name")
          local vm="dm-$name" provider="dm-$name" port statedir
          port=$(port_for "$name")
          statedir="$STATE/$name"

          # Phase 4: resolve the target creil repo + operator Forgejo token up
          # front, so a missing token fails before we build images / boot a VM.
          # Non-creil sources (or --no-push-cred) just get no push credential.
          local token=""
          if [[ "$push_cred" -eq 1 ]]; then
              [[ -n "$repo" ]] || repo=$(parse_repo "$source")
              if [[ -n "$repo" ]]; then
                  token=$(forgejo_token) || return 1
              else
                  echo "note: no creil repo detected for '$source'; the sandbox will" >&2
                  echo "      have no git-push credential (pass --repo owner/name)." >&2
              fi
          fi

          # Surface the OIDC login prompt up front (stderr visible) so the later
          # backgrounded port-forward + stderr-suppressed cluster calls reuse a
          # warm token instead of dead-hanging on an unseen auth-code prompt.
          dm_login || return 1

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
          create_vm "$name" "$memory" "$cpu" "$disk"

          echo "==> waiting for VM to be ready"
          kubectl wait "vm/$vm" -n "$NAMESPACE" --for=condition=Ready --timeout=300s
          echo "==> waiting for guest agent (ssh key injection)"
          kubectl wait "vmi/$vm" -n "$NAMESPACE" --for=condition=AgentConnected --timeout=180s

          mkdir -p "$statedir"
          echo "$port" >"$statedir/port"
          # Record the VMI uid so `rescue` can tell a wedged-but-alive VM (scratch
          # intact, recoverable) apart from one whose virt-launcher pod was OOM-
          # killed and recreated by runStrategy=Always (scratch emptyDisk wiped,
          # nothing left to rescue). A changed uid means the latter. Best-effort:
          # the machine is already up, so a bookkeeping miss here must not abort
          # `up` — but warn rather than silently leaving rescue half-blind, and
          # don't leave an empty file behind to be misread as a recorded uid.
          if ! kubectl get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' \
              >"$statedir/vmi_uid"; then
              rm -f "$statedir/vmi_uid"
              echo "warning: could not record VMI uid; 'rescue' won't be able to" >&2
              echo "         detect a pod-restart scratch wipe for this machine" >&2
          fi

          # The guest needs ~10-30s after AgentConnected to finish DHCP before its
          # sshd is reachable through the masquerade pod (an early connect fails
          # "no route to host" while the guest network is still coming up), and
          # `kubectl port-forward` *exits* on that failure. So (re)establish the
          # tunnel each iteration — ensure_portforward is a no-op while it's alive
          # and revives it if it died.
          echo "==> waiting for sshd"
          local ready=0
          for _ in $(seq 1 45); do
              ensure_portforward "$name" "$port" "$statedir"
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

          # Phase 4: mint + inject the scoped deploy key (the sandbox's ONLY push
          # credential). Only when a creil repo was resolved and a token is present.
          if [[ -n "$repo" && -n "$token" ]]; then
              echo "==> provisioning scoped push credential ($FORGEJO_USER SSH key for $repo)"
              provision_push_cred "$name" "$statedir" "$token" \
                  || echo "warning: $FORGEJO_USER SSH-key provisioning failed; sandbox has no push credential" >&2
          fi

          echo
          echo "dev machine '$name' is up. Connect with:  dev-machine ssh $name"
      }

      cmd_ssh() {
          local name="" recover=0
          while [[ $# -gt 0 ]]; do
              case "$1" in
                  --recover) recover=1; shift ;;
                  -*) echo "unknown flag: $1" >&2; return 1 ;;
                  *)
                      if [[ -z "$name" ]]; then name="$1"; shift
                      else echo "unexpected arg: $1" >&2; return 1; fi
                      ;;
              esac
          done
          name=$(sanitize "$name")
          [[ -n "$name" ]] || { echo "usage: dev-machine ssh <name> [--recover]" >&2; return 1; }
          local statedir="$STATE/$name"
          [[ -d "$statedir" ]] || { echo "no such dev machine: $name" >&2; return 1; }
          dm_login || return 1
          ensure_portforward "$name" "$(cat "$statedir/port")" "$statedir" || return 1

          # --recover: the in-VM devpod agent/container is gone — typically after
          # the VM crashed and runStrategy=Always booted a fresh one (the scratch
          # docker data-root is an emptyDisk, so it comes back blank). `devpod up`
          # on the existing workspace id re-runs the agent and rebuilds the
          # devcontainer over the (re-established) tunnel, which is what gets the
          # `devpod ssh` below working again. NOTE: the rebuilt container is fresh,
          # so the per-session cc push key injected by `up` is gone — re-run
          # `dev-machine up <source>` if you need to push again; --recover just
          # gets you a working shell back.
          if [[ "$recover" -eq 1 ]]; then
              echo "==> --recover: restarting the devcontainer agent (devpod up)"
              devpod up "$name" --provider "dm-$name" --ide none || {
                  echo "recover failed — the VM itself may be down/looping." >&2
                  echo "check 'dev-machine list' and 'dev-machine console $name'." >&2
                  return 1
              }
          fi
          # Lockdown flags: --start-services=false stops devpod proxying the
          # operator's git/docker credentials into the session, and
          # --agent-forwarding=false stops forwarding the operator's SSH agent in
          # (devpod defaults it ON) — the injected cc key is the sandbox's only
          # identity. Disabling agent-forwarding also avoids devpod's noisy teardown
          # error on logout (the forwarded-agent channel closing without a clean
          # exit-status). Trade-off: start-services=false also forgoes devpod
          # port-forwarding; run `devpod ssh <name>` directly if you need that.
          devpod ssh "$name" --start-services=false --agent-forwarding=false
      }

      # Recreate just the devcontainer on an already-running VM — the fast
      # iteration loop for devcontainer.json / dev-image changes, WITHOUT the
      # multi-minute VM create+boot of a full `down`/`up`. `devpod up --recreate`
      # tears the container down and rebuilds it over the existing tunnel; the VM,
      # its scratch disk, and the local state all survive. A recreate produces a
      # fresh container, so the per-session cc push key `up` injected is gone —
      # re-inject it from saved state (the key still lives on the cc account; no
      # token or re-mint needed) so the refreshed container can push immediately.
      cmd_refresh() {
          local name=""
          while [[ $# -gt 0 ]]; do
              case "$1" in
                  -*) echo "unknown flag: $1" >&2; return 1 ;;
                  *)
                      if [[ -z "$name" ]]; then name="$1"; shift
                      else echo "unexpected arg: $1" >&2; return 1; fi
                      ;;
              esac
          done
          name=$(sanitize "$name")
          [[ -n "$name" ]] || { echo "usage: dev-machine refresh <name>" >&2; return 1; }
          local statedir="$STATE/$name"
          [[ -d "$statedir" ]] || { echo "no such dev machine: $name" >&2; return 1; }
          dm_login || return 1
          [[ -f "$statedir/port" ]] || {
              echo "no recorded port for $name; was it created by 'dev-machine up'?" >&2
              return 1
          }
          ensure_portforward "$name" "$(cat "$statedir/port")" "$statedir" || return 1

          echo "==> recreating the devcontainer (devpod up --recreate; VM untouched)"
          devpod up "$name" --provider "dm-$name" --ide none --recreate || {
              echo "refresh failed; inspect with 'dev-machine list' / 'dev-machine console $name'." >&2
              return 1
          }
          if [[ -f "$statedir/deploy_key" ]]; then
              echo "==> re-injecting the scoped push credential"
              inject_deploy_key "$name" "$statedir/deploy_key" \
                  || echo "warning: push-credential re-injection failed; re-run 'dev-machine up' to restore it" >&2
          fi
          echo
          echo "dev machine '$name' refreshed. Connect with:  dev-machine ssh $name"
      }

      # Serial console to the VM — uses the pinned virtctl + the wrapper's OIDC
      # kubeconfig, avoiding the version skew / missing-KUBECONFIG that an ad-hoc
      # `nix shell nixpkgs#kubevirt -c virtctl console` hits. Handy for debugging a
      # VM whose sshd/network never came up (the base image has serial autologin).
      cmd_console() {
          local name
          name=$(sanitize "''${1:-}")
          [[ -n "$name" ]] || {
              echo "usage: dev-machine console <name>" >&2
              return 1
          }
          dm_login || return 1
          virtctl console "vmi/dm-$name" -n "$NAMESPACE"
      }

      # Best-effort RECOVERY of a wedged-but-alive dev machine back to a working
      # devcontainer session — with a safety backup of the working tree taken
      # around the attempt. Targets failure mode 1: a guest-side OOM/oomd kill
      # reaped the devcontainer or the devpod agent (sshd + qemu-guest-agent are
      # pinned OOMScoreAdjust=-900, so they survive), leaving the VM up and the
      # scratch disk — and the workspace on it — intact, but the session dead.
      # The cure is the same `devpod up` the in-VM agent needs to come back;
      # rescue wraps it with an honest diagnosis and an insurance copy first, so
      # the PREFERRED outcome is a usable machine again, not a pile of salvaged
      # files. (Heavier sibling of `ssh --recover`: it diagnoses + backs up.)
      #
      # It CANNOT recover the WORK after failure mode 2: a NODE-level OOM kill of
      # the virt-launcher pod. runStrategy=Always recreates the VMI and scratch
      # is a KubeVirt emptyDisk (tied to the pod), so the workspace is destroyed
      # the instant the pod dies — before any rescue could run. Stage 0 detects
      # that (recorded VMI uid no longer matches) and says so: the machine can be
      # rebuilt, but the uncommitted work is gone. Durable fix is persistent
      # scratch (a PVC), deferred until iSCSI lands.
      #
      # Non-destructive: never deletes the VM or local state. It restarts the
      # devcontainer and copies a backup OUT to $STATE/<name>/rescue/<ts>/.
      #   default      back up, then `devpod up` to restore a working session.
      #   --no-revive  back up only (when you intend to tear the VM down after).
      cmd_rescue() {
          local name="" revive=1
          while [[ $# -gt 0 ]]; do
              case "$1" in
                  --no-revive) revive=0; shift ;;
                  -*) echo "unknown flag: $1" >&2; return 1 ;;
                  *)
                      if [[ -z "$name" ]]; then name="$1"; shift
                      else echo "unexpected arg: $1" >&2; return 1; fi
                      ;;
              esac
          done
          name=$(sanitize "$name")
          [[ -n "$name" ]] || { echo "usage: dev-machine rescue <name> [--no-revive]" >&2; return 1; }
          local statedir="$STATE/$name"
          [[ -d "$statedir" ]] || { echo "no such dev machine: $name" >&2; return 1; }
          dm_login || return 1

          # ── Stage 0: assess — and diagnose honestly when work can't be saved ──
          # --ignore-not-found makes "VMI absent" an empty string with exit 0, so a
          # genuine cluster/auth error (any other non-zero) still aborts under set
          # -e with kubectl's own message — rather than being misreported as "the
          # VM is gone".
          local vm="dm-$name" cur_uid rec_uid phase
          cur_uid=$(kubectl get vmi "$vm" -n "$NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.uid}')
          if [[ -z "$cur_uid" ]]; then
              echo "VMI $vm not found — the VM is gone." >&2
              echo "rebuild from scratch with: dev-machine up <repo> --name $name" >&2
              echo "(clear leftover local state first: dev-machine down $name --no-agent)" >&2
              return 1
          fi
          # vmi_uid is optional state (absent for machines created before this
          # existed, or if `up`'s best-effort record failed). Treat absence as
          # "can't tell" and skip the wipe check; only read it when present, so a
          # real read error on an existing file is not swallowed.
          rec_uid=""
          [[ -f "$statedir/vmi_uid" ]] && rec_uid=$(cat "$statedir/vmi_uid")
          if [[ -n "$rec_uid" && "$rec_uid" != "$cur_uid" ]]; then
              echo "the VM was restarted (VMI uid changed: $rec_uid -> $cur_uid)." >&2
              echo "scratch is an emptyDisk tied to the virt-launcher pod, so the" >&2
              echo "devcontainer filesystem — and any uncommitted work — was wiped by" >&2
              echo "the restart. The machine can be rebuilt, but that work is gone:" >&2
              echo "  dev-machine ssh $name --recover   # rebuild the devcontainer (fresh clone)" >&2
              return 1
          fi
          # The VMI exists (cur_uid is set), so this is not a not-found; a non-zero
          # here is a real error and should abort.
          phase=$(kubectl get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
          if [[ "$phase" != "Running" ]]; then
              echo "VMI $vm phase is '$phase' (not Running); cannot reach the guest yet." >&2
              echo "retry once it is Running, or inspect with 'dev-machine console $name'." >&2
              return 1
          fi

          # ── Stage 1: VM sshd reachable → extract over the OOM-protected sshd ───
          [[ -f "$statedir/port" ]] || {
              echo "no recorded port for $name; was it created by 'dev-machine up'?" >&2
              return 1
          }
          local port
          port=$(cat "$statedir/port")

          echo "==> probing VM sshd"
          local reachable=0 _
          for _ in $(seq 1 10); do
              # Tolerated, not swallowed: a transient failure here (e.g. the
              # port-forward target not up for a beat) is expected mid-retry, and
              # ensure_portforward prints its own reason to stderr. The ssh probe
              # below is the real success gate; the post-loop check reports if it
              # never came up.
              ensure_portforward "$name" "$port" "$statedir" || true
              if ssh -p "$port" -o StrictHostKeyChecking=no \
                  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 \
                  -o BatchMode=yes dev@127.0.0.1 true 2>/dev/null; then
                  reachable=1
                  break
              fi
              sleep 2
          done
          if [[ "$reachable" -ne 1 ]]; then
              # VM is Running but its sshd is unreachable (rare — sshd is
              # OOM-protected). Fall back to a manual recover/pull over the
              # serial console.
              echo "VM sshd is unreachable, though the VM is Running (rare — sshd is" >&2
              echo "OOM-protected). Recover/extract manually over the serial console:" >&2
              echo "  dev-machine console $name      # root autologin, then e.g.:" >&2
              echo "  #   docker ps; docker start <id>" >&2
              echo "  #   docker cp <id>:/workspaces/$name /root/$name-rescue" >&2
              return 1
          fi

          local rescuedir
          rescuedir="$statedir/rescue/$(date +%Y%m%d-%H%M%S)"
          mkdir -p "$rescuedir"

          # Safety backup BEFORE we touch the container, in case recovery
          # surprises us. Works only against a RUNNING container; if the
          # container was killed this no-ops now and we retry after the revive.
          echo "==> backing up the working tree (safety net)"
          local backed_up=0
          rescue_backup "$name" "$port" "$rescuedir" && backed_up=1

          # --no-revive: stop here; the caller only wanted the data out.
          if [[ "$revive" -eq 0 ]]; then
              if [[ "$backed_up" -eq 1 ]]; then
                  echo
                  echo "backed up '$name' into: $rescuedir"
                  echo "  contents:"
                  find "$rescuedir" -maxdepth 1 -mindepth 1 -printf '    %f\n'
                  rescue_print_reapply "$rescuedir"
                  echo "the VM is untouched; tear down with 'dev-machine down $name --no-agent'."
                  return 0
              fi
              echo "nothing running to back up; drop --no-revive to restart it first." >&2
              return 1
          fi

          # ── Recover the devcontainer itself (the preferred outcome) ───────────
          # devpod up restarts a stopped/killed container and re-injects a dead
          # agent over the (re-established) tunnel. Stage 0 proved scratch wasn't
          # wiped, so the workspace persists across this — no work is lost.
          echo "==> recovering the devcontainer (devpod up)"
          if ! devpod up "$name" --provider "dm-$name" --ide none; then
              echo >&2
              echo "could not restore a working devcontainer." >&2
              if [[ "$backed_up" -eq 1 ]]; then
                  echo "your work is safe in $rescuedir; rebuild, then re-apply it:" >&2
                  echo "  dev-machine down $name --no-agent && dev-machine up <repo> --name $name" >&2
                  rescue_print_reapply "$rescuedir" >&2
              else
                  echo "and no backup could be taken (see $rescuedir/extract.log)." >&2
                  echo "try the serial console: dev-machine console $name" >&2
              fi
              return 1
          fi

          # Container is back; grab the safety copy now if the pre-revive one
          # no-op'd (the container had been stopped, so docker couldn't read it).
          if [[ "$backed_up" -eq 0 ]]; then
              echo "==> backing up the working tree (post-recovery safety net)"
              rescue_backup "$name" "$port" "$rescuedir" && backed_up=1
          fi

          echo
          echo "dev machine '$name' recovered. Connect with:  dev-machine ssh $name"
          if [[ "$backed_up" -eq 1 ]]; then
              echo "a safety backup of the working tree is in: $rescuedir"
          else
              echo "(note: a working-tree backup could not be captured — commit early;" >&2
              echo " see $rescuedir/extract.log for why.)" >&2
          fi
      }

      cmd_list() {
          dm_login || return 1
          echo "VMs:"
          kubectl get vm -n "$NAMESPACE" 2>/dev/null || true
          echo
          echo "Workspaces:"
          devpod list
      }

      cmd_down() {
          local name="" no_agent=0
          while [[ $# -gt 0 ]]; do
              case "$1" in
                  --no-agent) no_agent=1; shift ;;
                  -*) echo "unknown flag: $1" >&2; return 1 ;;
                  *)
                      if [[ -z "$name" ]]; then name="$1"; shift
                      else echo "unexpected arg: $1" >&2; return 1; fi
                      ;;
              esac
          done
          name=$(sanitize "$name")
          [[ -n "$name" ]] || { echo "usage: dev-machine down <name> [--no-agent]" >&2; return 1; }
          local statedir="$STATE/$name"
          dm_login || return 1

          # Phase 4: revoke the per-session deploy key on creil before teardown.
          if [[ -f "$statedir/deploy_key_id" ]]; then
              local token
              if token=$(forgejo_token 2>/dev/null); then
                  revoke_push_cred "$statedir" "$token"
              else
                  echo "warning: no Forgejo token; deploy key not revoked (revoke it manually)" >&2
              fi
          fi

          echo "==> tearing down $name"
          # `devpod delete` normally SSHes into the VM to run the in-container
          # agent teardown. When the VM has crashed/OOM-killed that tunnel is dead,
          # and the call blocks on the unreachable agent — which is why ordinary
          # `down` wedges. --no-agent skips the in-VM teardown: we drop the VM +
          # secret FIRST (the container dies with the VM regardless, so the agent
          # teardown is moot), which makes the SSH target provably gone, then
          # `devpod delete --force` only has to clear devpod's local bookkeeping
          # (connection refused → fast fail → --force removes local state). The
          # `timeout` is a backstop so a wedged devpod can never re-hang `down`.
          if [[ "$no_agent" -eq 1 ]]; then
              echo "    (--no-agent: skipping in-VM devpod teardown)"
              kubectl delete vm "dm-$name" -n "$NAMESPACE" --ignore-not-found
              kubectl delete secret "dm-$name-ssh-key" -n "$NAMESPACE" --ignore-not-found
              if [[ -f "$statedir/portforward.pid" ]]; then
                  kill "$(cat "$statedir/portforward.pid")" 2>/dev/null || true
              fi
              timeout 30 devpod delete "$name" --force 2>/dev/null || true
          else
              devpod delete "$name" --force 2>/dev/null || true
              kubectl delete vm "dm-$name" -n "$NAMESPACE" --ignore-not-found
              kubectl delete secret "dm-$name-ssh-key" -n "$NAMESPACE" --ignore-not-found
              if [[ -f "$statedir/portforward.pid" ]]; then
                  kill "$(cat "$statedir/portforward.pid")" 2>/dev/null || true
              fi
          fi
          devpod provider delete "dm-$name" 2>/dev/null || true
          rm -rf "$statedir"
      }

      cmd_publish_base() {
          require_login
          build_and_push dev-machine-image "$BASE_IMAGE"
      }

      usage() {
          cat >&2 <<'USAGE'
      dev-machine — locked-down LLM dev machines on KubeVirt

        dev-machine up [<repo>] [--name N] [--repo owner/name] [--no-rebuild] [--no-push-cred] [--memory 8Gi] [--cpu 4] [--disk 60Gi]
                                             (omit <repo> to use the current directory's checkout)
        dev-machine ssh <name> [--recover]   (--recover: restart a dead devcontainer agent before ssh)
        dev-machine refresh <name>           (recreate just the devcontainer on the running VM — fast iterate on devcontainer.json)
        dev-machine console <name>
        dev-machine list
        dev-machine rescue <name> [--no-revive] (recover a wedged-but-alive VM to a working devcontainer; backs up the working tree first. --no-revive: back up only)
        dev-machine down <name> [--no-agent] (--no-agent: skip in-VM devpod teardown for a crashed/OOM VM)
        dev-machine publish-base

      escape hatches (run with the wrapper's pinned tools + OIDC kubeconfig):
        dev-machine kubectl <args...>
        dev-machine virtctl <args...>
      USAGE
      }

      cmd="''${1:-}"
      [[ $# -gt 0 ]] && shift || true
      case "$cmd" in
          up) cmd_up "$@" ;;
          ssh) cmd_ssh "$@" ;;
          refresh) cmd_refresh "$@" ;;
          console) cmd_console "$@" ;;
          rescue) cmd_rescue "$@" ;;
          list | ls) cmd_list "$@" ;;
          down | rm) cmd_down "$@" ;;
          publish-base) cmd_publish_base "$@" ;;
          kubectl) kubectl "$@" ;;
          virtctl) virtctl "$@" ;;
          "" | -h | --help | help) usage ;;
          *) echo "unknown command: $cmd" >&2; usage; exit 1 ;;
      esac
    '';
  };
in {
  options.programs.dev-machine = {
    enable = lib.mkEnableOption "the locked-down KubeVirt LLM dev-machine wrappers";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "dev-machines";
      description = "k8s namespace the dev-machine VMs + secrets live in (Phase 5 hangs a default-deny-egress NetworkPolicy off it).";
    };

    registry = lib.mkOption {
      type = lib.types.str;
      default = "forgejo.internal/mutantmell";
      description = "creil (Forgejo) registry path holding the base containerDisk and the dev image.";
    };

    flake = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/git/dotfiles";
      description = "Path to the dotfiles flake the images are built from.";
    };

    kubeconfig = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.kube/erebonia-oidc.yaml";
      description = "Standalone OIDC kubeconfig (kept out of ~/.kube/config on purpose; see kube.nix).";
    };

    sshPubKey = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
      description = ''
        The operator's primary pubkey the guest agent injects into the VM's `dev`
        user (KubeVirt AccessCredentials). Kept for backward compatibility; it is
        the default sole entry of `sshPubKeys`. To inject more than one key
        (e.g. operator + mobile), set `sshPubKeys` instead.
      '';
    };

    sshPubKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [cfg.sshPubKey];
      defaultText = lib.literalExpression "[ config.programs.dev-machine.sshPubKey ]";
      description = ''
        Phase 6: ALL pubkey paths the guest agent injects into the VM's `dev`
        user (KubeVirt AccessCredentials), letting a mobile operator key attach
        ALONGSIDE the workstation key without an image rebuild. `create_vm`
        concatenates these into one authorized_keys blob the AccessCredentials
        secret carries; the guest agent appends every line. Defaults to just
        `[ sshPubKey ]`, so single-key setups need no change.
      '';
    };

    defaultMemory = lib.mkOption {
      type = lib.types.str;
      default = "8Gi";
      description = "Default VM memory request.";
    };

    defaultCpu = lib.mkOption {
      type = lib.types.str;
      default = "4";
      description = "Default VM vCPU cores.";
    };

    defaultDisk = lib.mkOption {
      type = lib.types.str;
      default = "60Gi";
      description = "Default capacity of the ephemeral scratch disk backing docker's data-root (dev image + in-container builds, incl. nixosTest VM images). Override per-session with `--disk`.";
    };

    forgejoApi = lib.mkOption {
      type = lib.types.str;
      default = "https://forgejo.internal/api/v1";
      description = "Forgejo (creil) API base URL used to mint/revoke the per-session deploy key.";
    };

    forgejoSshUser = lib.mkOption {
      type = lib.types.str;
      default = "forgejo";
      description = ''
        SSH login user for git-over-SSH to forgejo (the `<user>@forgejo.internal` in
        rewritten clone URLs). A Forgejo using the OS sshd + authorized-keys
        integration uses its RUN_USER here (default `forgejo`), NOT `git`. The key
        still identifies the actual account (forgejoUser); this is only the transport.
      '';
    };

    forgejoTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Path to a file holding the bot user's (forgejoUser) Forgejo token
        (write:user scope). Used ONLY to add/remove that user's per-session SSH
        keys (POST/DELETE /user/keys); it never enters the VM/sandbox. The keys
        live on the bot account, so pushes authenticate as it — scope that user's
        repo access to bound the blast radius. Point this at a sops-decrypted tmpfs
        secret path, e.g. config.sops.secrets."dev-machine-forgejo-token".path.
      '';
    };

    forgejoUser = lib.mkOption {
      type = lib.types.str;
      default = "cc";
      description = ''
        The Forgejo bot user the dev machines push as — the owner of the token in
        forgejoTokenFile. Drives the default commit identity and user-facing
        messages; the per-session SSH key actually lands on whichever account owns
        that token (/user/keys), so keep this in sync with the token's owner.
      '';
    };

    commitName = lib.mkOption {
      type = lib.types.str;
      default = cfg.forgejoUser;
      defaultText = lib.literalExpression "config.programs.dev-machine.forgejoUser";
      description = "git user.name set inside the sandbox (commit author). Defaults to the bot user.";
    };

    commitEmail = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.forgejoUser}@forgejo.internal";
      defaultText = lib.literalExpression ''"''${config.programs.dev-machine.forgejoUser}@forgejo.internal"'';
      description = "git user.email set inside the sandbox. Set to one of the bot user's Forgejo emails so commits map to it.";
    };

    caCert = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Optional CA certificate path for TLS verification of the Forgejo API (internal step-ca root).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [dev-machine];
  };
}
