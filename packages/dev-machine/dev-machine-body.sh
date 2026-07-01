# shellcheck shell=bash

devpod_up() {
  local args=("$@")
  if [[ $AGENTS_DOTFILES_ENABLE == "true" && -n $AGENTS_DOTFILES_URL ]]; then
    args+=(--dotfiles "$AGENTS_DOTFILES_URL")
    if [[ -n $AGENTS_DOTFILES_SCRIPT ]]; then
      args+=(--dotfiles-script "$AGENTS_DOTFILES_SCRIPT")
    fi
  fi
  devpod up "${args[@]}"
}

read_agents_manifest() {
  local manifest=$1
  python3 - "$manifest" <<'PY'
import sys
import tomllib

manifest = sys.argv[1]
try:
    with open(manifest, "rb") as f:
        data = tomllib.load(f)
except tomllib.TOMLDecodeError as e:
    print(f"{manifest}: {e}", file=sys.stderr)
    raise SystemExit(1)

dotfiles = data.get("dotfiles", {})
url = dotfiles.get("url") or dotfiles.get("repository") or ""
script = dotfiles.get("script") or dotfiles.get("installScript") or "install.sh"

if not isinstance(url, str) or not isinstance(script, str):
    print("dotfiles.url/repository and dotfiles.script/installScript must be strings", file=sys.stderr)
    raise SystemExit(1)

print(url)
print(script)
PY
}

resolve_agents_manifest() {
  local source=$1 local_hint=${2:-}
  local tmp="" manifest="" parsed_file="" url script

  if [[ -n $local_hint && -f "$local_hint/$AGENTS_MANIFEST_PATH" ]]; then
    manifest="$local_hint/$AGENTS_MANIFEST_PATH"
  elif [[ -d $source && -f "$source/$AGENTS_MANIFEST_PATH" ]]; then
    manifest="$source/$AGENTS_MANIFEST_PATH"
  elif [[ -n $source ]]; then
    tmp=$(mktemp -d)
    if git clone --depth=1 --filter=blob:none --no-checkout "$source" "$tmp" >/dev/null 2>&1; then
      if git -C "$tmp" show "HEAD:$AGENTS_MANIFEST_PATH" >"$tmp/agents.toml" 2>/dev/null; then
        manifest="$tmp/agents.toml"
      fi
    fi
  fi

  if [[ -n $manifest ]]; then
    parsed_file=$(mktemp)
    if ! read_agents_manifest "$manifest" >"$parsed_file"; then
      rm -f "$parsed_file"
      [[ -z $tmp ]] || rm -rf "$tmp"
      echo "invalid agents manifest: $manifest" >&2
      return 1
    fi
    readarray -t parsed <"$parsed_file"
    rm -f "$parsed_file"
    url=${parsed[0]:-}
    script=${parsed[1]:-install.sh}
    AGENTS_DOTFILES_URL="$url"
    AGENTS_DOTFILES_SCRIPT="$script"
  fi

  [[ -z ${tmp:-} ]] || rm -rf "$tmp"
}

save_agents_dotfiles_state() {
  local statedir=$1
  mkdir -p "$statedir"
  printf '%s\n' "$AGENTS_DOTFILES_ENABLE" >"$statedir/agents_dotfiles_enable"
  printf '%s\n' "$AGENTS_DOTFILES_URL" >"$statedir/agents_dotfiles_url"
  printf '%s\n' "$AGENTS_DOTFILES_SCRIPT" >"$statedir/agents_dotfiles_script"
}

load_agents_dotfiles_state() {
  local statedir=$1
  [[ -f "$statedir/agents_dotfiles_enable" ]] && AGENTS_DOTFILES_ENABLE=$(cat "$statedir/agents_dotfiles_enable")
  [[ -f "$statedir/agents_dotfiles_url" ]] && AGENTS_DOTFILES_URL=$(cat "$statedir/agents_dotfiles_url")
  [[ -f "$statedir/agents_dotfiles_script" ]] && AGENTS_DOTFILES_SCRIPT=$(cat "$statedir/agents_dotfiles_script")
}

# DNS-1123-safe machine name derived from a repo/path basename.
sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40
}

# ── Slot model (bring-up checklist D.4/D.5) ──────────────────────────────
# The registry declares 16 STATIC dev slots `dev-1`..`dev-16` (network.nix
# cluster zone → 10.97.51.10..25 → authoritative `dev-N.internal` DNS). A VM
# OCCUPIES a free slot for its life: the launcher pins the slot's NAD
# (carrying its IP) + a deterministic MAC, and labels the VM `dev-machine-slot
# =dev-N`. Occupancy is read back from that label across all machines, so no
# local bookkeeping can drift and re-`up` of a name reuses its slot.
SLOT_COUNT=16

# The slots currently taken by EXISTING VMs in the namespace — read from the
# cluster (the source of truth), one `dev-N` per line.
occupied_slots() {
  kubectl get vm -n "$NAMESPACE" \
    -o jsonpath="{range .items[*]}{.metadata.labels['dev-machine-slot']}{\"\n\"}{end}" \
    2>/dev/null | grep -v '^$' || true
}

# The slot a given machine's VM already occupies (empty if the VM is absent
# or unlabelled). Lets re-`up`/ssh/down resolve "which dev-N is this machine".
slot_of_vm() {
  kubectl get vm "dm-$1" -n "$NAMESPACE" \
    -o jsonpath="{.metadata.labels['dev-machine-slot']}" 2>/dev/null || true
}

# Pick the lowest-numbered free slot, or fail when all SLOT_COUNT are taken
# (D.5 — refuse rather than collide). Prints `dev-N`.
assign_free_slot() {
  local taken n
  taken=$(occupied_slots)
  for n in $(seq 1 "$SLOT_COUNT"); do
    if ! grep -qx "dev-$n" <<<"$taken"; then
      echo "dev-$n"
      return 0
    fi
  done
  echo "all $SLOT_COUNT dev slots (dev-1..dev-$SLOT_COUNT) are occupied;" >&2
  echo "tear one down with 'dev-machine down <name>' or raise the slot count" >&2
  echo "in the registry (network.nix cluster zone)." >&2
  return 1
}

# Deterministic, locally-administered MAC for a slot (dev-N → host-id 9+N →
# 02:51:51:00:00:<hostid-hex>). Stable across a slot's reuse so bt8gw's
# neighbour table doesn't carry a stale entry for the slot IP.
mac_for_slot() {
  local n hostid
  n=${1#dev-}
  hostid=$((9 + n))
  printf '02:51:51:00:00:%02x\n' "$hostid"
}

# The routable hostname a slot's VM answers on — its authoritative
# `dev-N.internal` registry record (D.6: operator access is direct SSH here,
# no port-forward). Reachable from edith (lab/21) because bt8gw already
# permits lab→cluster (and wg-vpn→cluster) broadly.
host_for_slot() { echo "$1.internal"; }

host_for_machine() {
  local name=$1
  local statedir="$STATE/$name" slot=""
  slot=$(cat "$statedir/slot" 2>/dev/null || true)
  [[ -n $slot ]] || slot=$(slot_of_vm "$name")
  [[ -n $slot ]] || return 1
  host_for_slot "$slot"
}

# Direct SSH into a machine's dev user at its slot host. Ephemeral VMs reuse
# slot names/IPs, so host keys churn — relax host-key checking (these are
# disposable sandboxes reachable only across the bt8gw-confined VLAN 51).
ssh_dev() {
  local host=$1
  shift
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o BatchMode=yes "dev@$host" "$@"
}

shell_quote() {
  jq -rn --arg v "$1" '$v|@sh'
}

# Force the interactive OIDC token mint up front, with stderr VISIBLE. The
# OIDC kubeconfig authenticates via an exec plugin (kubectl-oidc_login,
# authcode-keyboard): when the cached token has lapsed it prints an Authelia
# URL and waits on stdin for the pasted code. That prompt rides kubectl's
# stderr, so any cluster call that suppresses stderr (e.g. cmd_list's
# `get vm 2>/dev/null`) silently dead-hangs waiting for a code the operator
# never sees. Run one cheap,
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

require_agents_dotfiles_access() {
  if [[ $AGENTS_DOTFILES_ENABLE != "true" || -z $AGENTS_DOTFILES_URL ]]; then
    return 0
  fi
  if ! git ls-remote "$AGENTS_DOTFILES_URL" HEAD >/dev/null 2>&1; then
    echo "agents dotfiles repository is not readable from this workstation:" >&2
    echo "  $AGENTS_DOTFILES_URL" >&2
    echo "DevPod must be able to clone it during 'devpod up', before the" >&2
    echo "Forgejo agent credential is injected into the sandbox." >&2
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

# ── Phase 4: scoped git/API credential on the cc bot account ─────────────
# The cc bot's Forgejo token lives in a sops-decrypted tmpfs file
# (forgejoTokenFile); read it on demand and inject it into the sandbox so
# agents can use tea and HTTPS git pushes as cc.
forgejo_token() {
  if [[ -z $FORGEJO_TOKEN_FILE || ! -f $FORGEJO_TOKEN_FILE ]]; then
    echo "Forgejo token unavailable (programs.dev-machine.forgejoTokenFile)." >&2
    echo "add 'dev-machine-forgejo-token' to the edith sops secrets and" >&2
    echo "re-run home-manager switch, or pass --no-push-cred." >&2
    return 1
  fi
  cat "$FORGEJO_TOKEN_FILE"
}

forgejo_web_url() {
  local url=${FORGEJO_API%/}
  printf '%s\n' "${url%/api/v1}"
}

woodpecker_token() {
  if [[ -z $WOODPECKER_TOKEN_FILE ]]; then
    return 1
  fi
  if [[ ! -f $WOODPECKER_TOKEN_FILE ]]; then
    echo "Woodpecker token unavailable (programs.dev-machine.woodpeckerTokenFile)." >&2
    echo "add 'dev-machine-woodpecker-token' to the edith sops secrets and" >&2
    echo "re-run home-manager switch." >&2
    return 1
  fi
  cat "$WOODPECKER_TOKEN_FILE"
}

# Map a workspace source (creil URL or local checkout's origin) to its
# forgejo owner/repo; empty for non-creil sources (which get no push cred).
# Used to gate credential injection and to derive the cc fork remote.
parse_repo() {
  local src=$1 url rr
  if [[ -d $src ]]; then
    url=$(git -C "$src" remote get-url origin 2>/dev/null) || return 0
  else
    url=$src
  fi
  case "$url" in
  *forgejo.internal*) : ;;
  *) return 0 ;;
  esac
  rr=$(echo "$url" | sed -E 's#.*forgejo\.internal[:/]+##; s#/+$##; s#\.git$##')
  if [[ $rr =~ ^[^/]+/[^/]+$ ]]; then echo "$rr"; fi
}

# Push the tea/API token and git HTTPS credential config into the running
# devcontainer through the VM's rootful Podman socket. DevPod's `ssh --command`
# path has proven brittle for stdin delivery during setup; this still uses the
# same rootful runtime DevPod is configured to target, and keeps the token out
# of process argv.
inject_forgejo_credential() {
  local name=$1 token=$2 repo=$3 host=$4
  local name_q forgejo_user_q commit_name_q commit_email_q forgejo_url_q repo_q repo_name_q token_b64
  name_q=$(shell_quote "$name")
  forgejo_user_q=$(shell_quote "$FORGEJO_USER")
  commit_name_q=$(shell_quote "$COMMIT_NAME")
  commit_email_q=$(shell_quote "$COMMIT_EMAIL")
  forgejo_url_q=$(shell_quote "$(forgejo_web_url)")
  repo_q=$(shell_quote "$repo")
  repo_name_q=$(shell_quote "${repo##*/}")
  token_b64=$(printf '%s' "$token" | base64 -w0)
  # shellcheck disable=SC2016
  {
    printf '%s\n' \
      'set -e' \
      'umask 077' \
      "trap 'rm -f ~/.config/tea/token.b64 ~/.config/tea/token' EXIT" \
      'mkdir -p ~/.config/tea' \
      'chmod 700 ~/.config/tea' \
      "cat > ~/.config/tea/token.b64 <<'DM_TEA_TOKEN'" \
      "$token_b64" \
      'DM_TEA_TOKEN' \
      'base64 -d ~/.config/tea/token.b64 > ~/.config/tea/token' \
      'rm -f ~/.config/tea/token.b64' \
      'chmod 600 ~/.config/tea/token' \
      "git config --global user.name $commit_name_q" \
      "git config --global user.email $commit_email_q" \
      'tea login delete forgejo.internal >/dev/null 2>&1 || true' \
      "GITEA_SERVER_TOKEN=\$(cat ~/.config/tea/token) tea login add --name forgejo.internal --url $forgejo_url_q >/dev/null" \
      'tea login default forgejo.internal >/dev/null' \
      'tea whoami >/dev/null' \
      'user_enc=$(printf %s '"$forgejo_user_q"' | jq -sRr @uri)' \
      'token_enc=$(jq -sRr @uri < ~/.config/tea/token)' \
      'printf "https://%s:%s@forgejo.internal\n" "$user_enc" "$token_enc" > ~/.config/tea/git-credentials' \
      'chmod 600 ~/.config/tea/git-credentials' \
      'git config --global credential.helper "store --file $HOME/.config/tea/git-credentials"' \
      'git config --global --unset-all url.forgejo@forgejo.internal:.insteadOf >/dev/null 2>&1 || true' \
      'git config --global --unset-all url.ssh://forgejo@forgejo.internal/.insteadOf >/dev/null 2>&1 || true' \
      'rm -f ~/.config/tea/token' \
      'ws=' \
      "if [ -d /workspaces/$name_q/.git ]; then" \
      "  ws=/workspaces/$name_q" \
      'else' \
      '  for d in /workspaces/*; do' \
      '    if [ -d "$d/.git" ] && [ "$(basename "$d")" != agents ]; then ws=$d; break; fi' \
      '  done' \
      'fi' \
      "if [ -n \"\$ws\" ] && [ -n $repo_name_q ]; then" \
      '  if git -C "$ws" remote get-url origin >/dev/null 2>&1; then' \
      "    git -C \"\$ws\" remote set-url origin https://forgejo.internal/$repo_q.git" \
      '  else' \
      "    git -C \"\$ws\" remote add origin https://forgejo.internal/$repo_q.git" \
      '  fi' \
      '  git -C "$ws" remote set-url --push origin no_push_to_origin' \
      '  git -C "$ws" remote remove fork >/dev/null 2>&1 || true' \
      "  git -C \"\$ws\" remote add fork https://forgejo.internal/$FORGEJO_USER/$repo_name_q.git" \
      'fi'
  } | ssh_dev "$host" '
        set -e
        cid=$(
            podman-rootful ps -q | while read -r c; do
                if podman-rootful exec "$c" sh -c "test -d /workspaces/'"$name_q"'/.git"; then
                    printf "%s\n" "$c"
                    exit 0
                fi
                if podman-rootful exec "$c" sh -c "for d in /workspaces/*; do test \"\$(basename \"\$d\")\" = agents && continue; test -d \"\$d/.git\" && exit 0; done; exit 1"; then
                    printf "%s\n" "$c"
                    exit 0
                fi
            done
        )
        if [ -z "$cid" ]; then
            echo "no running devcontainer with a workspace checkout found" >&2
            exit 1
        fi
        exec podman-rootful exec -i --user agent "$cid" sh
    '
}

inject_woodpecker_credential() {
  local token=$1 host=$2
  local server_q token_b64
  server_q=$(shell_quote "$WOODPECKER_SERVER")
  token_b64=$(printf '%s' "$token" | base64 -w0)
  # shellcheck disable=SC2016
  {
    printf '%s\n' \
      'set -e' \
      'umask 077' \
      "trap 'rm -f ~/.config/woodpecker/token.b64' EXIT" \
      'mkdir -p ~/.config/woodpecker' \
      'chmod 700 ~/.config/woodpecker' \
      "cat > ~/.config/woodpecker/token.b64 <<'DM_WOODPECKER_TOKEN'" \
      "$token_b64" \
      'DM_WOODPECKER_TOKEN' \
      'base64 -d ~/.config/woodpecker/token.b64 > ~/.config/woodpecker/token' \
      'rm -f ~/.config/woodpecker/token.b64' \
      'chmod 600 ~/.config/woodpecker/token' \
      'cat > ~/.config/woodpecker/env <<'"'DM_WOODPECKER_ENV'" \
      "export WOODPECKER_SERVER=$server_q" \
      'export WOODPECKER_TOKEN="$(cat "$HOME/.config/woodpecker/token")"' \
      'DM_WOODPECKER_ENV' \
      'chmod 600 ~/.config/woodpecker/env' \
      'for profile in ~/.profile ~/.bashrc; do' \
      '  touch "$profile"' \
      '  if ! grep -qxF "[ -f \"\$HOME/.config/woodpecker/env\" ] && . \"\$HOME/.config/woodpecker/env\"" "$profile"; then' \
      '    printf "%s\n" "[ -f \"\$HOME/.config/woodpecker/env\" ] && . \"\$HOME/.config/woodpecker/env\"" >> "$profile"' \
      '  fi' \
      'done'
  } | ssh_dev "$host" '
        set -e
        cid=$(
            podman-rootful ps -q | while read -r c; do
                if podman-rootful exec "$c" sh -c "test -d /workspaces"; then
                    printf "%s\n" "$c"
                    exit 0
                fi
            done
        )
        if [ -z "$cid" ]; then
            echo "no running devcontainer found" >&2
            exit 1
        fi
        exec podman-rootful exec -i --user agent "$cid" sh
    '
}

# ── rescue: extract uncommitted work from a still-alive dev machine ────────
# The in-container extraction script, delivered through devpod. It
# finds the git workspace under /workspaces, packs a bundle of ALL refs (so
# committed-but-unpushed history survives), a working-tree patch, the git
# status, and the NON-IGNORED untracked files into one tarball, then base64s
# it to stdout. Untracked uses --exclude-standard so build junk on scratch
# (the nixosTest images, OCI layers) is skipped. Deliberately contains NO
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

extract_via_devpod() {
  local name=$1 script
  script=$(extract_script)
  devpod ssh "$name" --user agent --start-services=false --agent-forwarding=false \
    --command "$script"
}

# Capture the workspace (git bundle of all refs + working-tree patch +
# non-ignored untracked files) from the live VM into $rescuedir, unpacked.
# Returns 0 only when a non-empty payload was unpacked. This is the
# INSURANCE taken around a recovery attempt — never the end goal on its own.
# $rescuedir must exist.
rescue_backup() {
  local name=$1 host=$2 rescuedir=$3 out=""
  out=$(extract_via_devpod "$name" 2>>"$rescuedir/extract.log") || out=""
  [[ -n $out ]] || return 1
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
  local name=$1 memory=$2 cpu=$3 disk=$4 slot=$5
  local vm="dm-$name" secret="dm-$name-ssh-key"
  local mac nad
  mac=$(mac_for_slot "$slot")
  # Single shared macvtap NAD — slot identity is $mac (pinned below) + the
  # matching bt8gw DHCP reservation, not a per-slot NAD.
  nad="$NAMESPACE/cluster-vlan51"

  [[ ${#SSH_PUBKEYS[@]} -gt 0 ]] || {
    echo "no SSH pubkeys configured (programs.dev-machine.sshPubKeys)" >&2
    return 1
  }
  local k
  for k in "${SSH_PUBKEYS[@]}"; do
    [[ -f $k ]] || {
      echo "missing SSH pubkey: $k" >&2
      return 1
    }
  done

  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 ||
    kubectl create namespace "$NAMESPACE"

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
  cat "${SSH_PUBKEYS[@]}" >"$blob"
  kubectl create secret generic "$secret" -n "$NAMESPACE" \
    --from-file=key="$blob" --dry-run=client -o yaml |
    kubectl apply -f -

  # Patch the per-session fields into the Nix-authored skeleton (valid JSON
  # by construction) and apply. --argjson keeps cores an integer.
  jq \
    --arg vm "$vm" \
    --arg namespace "$NAMESPACE" \
    --arg name "$name" \
    --arg secret "$secret" \
    --arg base_image "$BASE_IMAGE" \
    --arg memory "$memory" \
    --argjson cpu "$cpu" \
    --arg disk "$disk" \
    --arg slot "$slot" \
    --arg mac "$mac" \
    --arg nad "$nad" \
    '.metadata.name = $vm
         | .metadata.namespace = $namespace
         | .metadata.labels."dev-machine-slot" = $slot
         | .spec.template.metadata.labels."dev-machine" = $name
         | .spec.template.metadata.labels."dev-machine-slot" = $slot
         | .spec.template.spec.domain.cpu.cores = $cpu
         | .spec.template.spec.domain.resources.requests.memory = $memory
         | .spec.template.spec.domain.devices.interfaces[0].macAddress = $mac
         | .spec.template.spec.networks[0].multus.networkName = $nad
         | (.spec.template.spec.volumes[] | select(.name == "rootdisk").containerDisk.image) = $base_image
         | (.spec.template.spec.volumes[] | select(.name == "scratch").emptyDisk.capacity) = $disk
         | .spec.template.spec.accessCredentials[0].sshPublicKey.source.secret.secretName = $secret' \
    "$VM_MANIFEST" |
    kubectl apply -f -
}

cmd_up() {
  local source="" name="" rebuild=0 memory cpu disk repo="" push_cred=1 manifest_hint=""
  memory="$DEFAULT_MEMORY"
  cpu="$DEFAULT_CPU"
  disk="$DEFAULT_DISK"
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-rebuild)
      rebuild=0
      shift
      ;;
    --rebuild)
      rebuild=1
      shift
      ;;
    --no-push-cred)
      push_cred=0
      shift
      ;;
    --name)
      name="$2"
      shift 2
      ;;
    --repo)
      repo="$2"
      shift 2
      ;;
    --memory)
      memory="$2"
      shift 2
      ;;
    --cpu)
      cpu="$2"
      shift 2
      ;;
    --disk)
      disk="$2"
      shift 2
      ;;
    -*)
      echo "unknown flag: $1" >&2
      return 1
      ;;
    *)
      if [[ -z $source ]]; then
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
  if [[ -z $source ]]; then
    if source=$(git -C "$PWD" remote get-url origin 2>/dev/null) && [[ -n $source ]]; then
      manifest_hint="$PWD"
      echo "==> no repo given; using current checkout's origin: $source" >&2
    else
      echo "usage: dev-machine up [<repo-url-or-path>] [--name N] [--repo owner/name] [--rebuild] [--no-push-cred] [--memory 8Gi] [--cpu 4] [--disk 60Gi]" >&2
      echo "       (omit the repo to use the current directory's origin remote URL)" >&2
      return 1
    fi
  fi
  resolve_agents_manifest "$source" "$manifest_hint" || return 1
  if [[ -z $name ]]; then
    name=$(basename "$source")
    name="${name%.git}"
  fi
  name=$(sanitize "$name")
  local vm="dm-$name" provider="dm-$name" slot host statedir
  statedir="$STATE/$name"
  save_agents_dotfiles_state "$statedir"

  # Phase 4: resolve the target creil repo + operator Forgejo token up front,
  # so a missing token fails before we build images / boot a VM. Non-creil
  # sources (or --no-push-cred) just get no git/API credential.
  local token="" woodpecker_api_token=""
  if [[ $push_cred -eq 1 ]]; then
    [[ -n $repo ]] || repo=$(parse_repo "$source")
    if [[ -n $repo ]]; then
      token=$(forgejo_token) || return 1
      printf '%s\n' "$repo" >"$statedir/repo"
    else
      echo "note: no creil repo detected for '$source'; the sandbox will" >&2
      echo "      have no git-push or tea credential (pass --repo owner/name)." >&2
      rm -f "$statedir/repo"
    fi
  fi
  if ! woodpecker_api_token=$(woodpecker_token 2>/dev/null); then
    woodpecker_api_token=""
  fi

  # Surface the OIDC login prompt up front (stderr visible) so the later
  # stderr-suppressed cluster calls reuse a warm token instead of
  # dead-hanging on an unseen auth-code prompt.
  dm_login || return 1

  # Resolve the slot this machine occupies (D.5): reuse the one its VM
  # already holds on re-`up`, else claim a free slot (fails if all taken).
  # Drives the routable host (`dev-N.internal`) + the VM's pinned IP/MAC.
  slot=$(slot_of_vm "$name")
  if [[ -n $slot ]]; then
    echo "==> reusing slot $slot held by $name" >&2
  else
    slot=$(assign_free_slot) || return 1
    echo "==> assigning slot $slot to $name" >&2
  fi
  host=$(host_for_slot "$slot")

  # Anything that touches creil (the optional rebuild push, the base presence
  # check, the base publish) needs the registry login — check once, up front.
  require_login
  require_agents_dotfiles_access

  if [[ $rebuild -eq 1 ]]; then
    build_and_push dev-machine-image "$BASE_IMAGE"
    build_and_push dev-machine-dev-image "$DEV_IMAGE"
  fi

  # The VM boots from the base containerDisk. Normal `up` reuses the published
  # image, but still publishes it on demand if it is missing from the registry.
  if ! skopeo inspect "docker://$BASE_IMAGE" >/dev/null 2>&1; then
    echo "==> base image $BASE_IMAGE not in registry; building + pushing it"
    build_and_push dev-machine-image "$BASE_IMAGE"
  fi

  echo "==> creating VM $vm on slot $slot ($host)"
  create_vm "$name" "$memory" "$cpu" "$disk" "$slot"

  echo "==> waiting for VM to be ready"
  kubectl wait "vm/$vm" -n "$NAMESPACE" --for=condition=Ready --timeout=300s
  echo "==> waiting for guest agent (ssh key injection)"
  kubectl wait "vmi/$vm" -n "$NAMESPACE" --for=condition=AgentConnected --timeout=180s

  mkdir -p "$statedir"
  echo "$slot" >"$statedir/slot"
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

  # The guest needs ~10-30s after AgentConnected to finish DHCP on its
  # VLAN-51 bridge NIC before sshd answers (an early connect fails while the
  # guest network is still coming up). Probe `dev-N.internal` directly (D.6
  # — no port-forward; this is the routable VLAN-51 host, reachable from
  # edith because bt8gw already forwards lab→cluster broadly).
  echo "==> waiting for sshd on $host"
  local ready=0
  for _ in $(seq 1 45); do
    if ssh_dev "$host" true 2>/dev/null; then
      ready=1
      break
    fi
    sleep 2
  done
  [[ $ready -eq 1 ]] || {
    echo "VM sshd at $host did not come up. Check the guest with:" >&2
    echo "dev-machine console $name" >&2
    return 1
  }

  # Per-machine ssh provider pinned directly to the slot host. Built-in ssh
  # is off so EXTRA_FLAGS' host-key relaxation applies — these VMs are
  # ephemeral and reuse slot names/IPs, so a pinned known_hosts entry only
  # gets in the way. The SSH provider still uses DevPod's Docker driver,
  # but points it at the VM's absolute `podman-rootful` wrapper, which
  # talks to /run/podman/podman.sock. Invoking plain `podman` as dev would
  # create a rootless workspace, which is not the validation target for Nix
  # uid-range builds.
  devpod provider delete "$provider" 2>/dev/null || true
  devpod provider add ssh --name "$provider" --use \
    -o HOST="dev@$host" \
    -o DOCKER_PATH=/run/current-system/sw/bin/podman-rootful \
    -o USE_BUILTIN_SSH=false \
    -o EXTRA_FLAGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

  echo "==> bringing the workspace up (devcontainer.json inside the VM)"
  devpod_up "$source" --id "$name" --provider "$provider" --ide none

  # Phase 4: inject the scoped Forgejo token for tea and HTTPS fork pushes.
  # Only when a creil repo was resolved and a token is present.
  if [[ -n $repo && -n $token ]]; then
    echo "==> provisioning scoped Forgejo credential ($FORGEJO_USER tea + HTTPS git for $repo)"
    inject_forgejo_credential "$name" "$token" "$repo" "$host" ||
      echo "warning: $FORGEJO_USER credential provisioning failed; sandbox has no push/API credential" >&2
  fi
  if [[ -n $woodpecker_api_token ]]; then
    echo "==> provisioning Woodpecker API credential"
    inject_woodpecker_credential "$woodpecker_api_token" "$host" ||
      echo "warning: Woodpecker credential provisioning failed; sandbox has no CI log API credential" >&2
  fi

  echo
  echo "dev machine '$name' is up. Connect with:  dev-machine ssh $name"
}

cmd_ssh() {
  local name="" recover=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --recover)
      recover=1
      shift
      ;;
    -*)
      echo "unknown flag: $1" >&2
      return 1
      ;;
    *)
      if [[ -z $name ]]; then
        name="$1"
        shift
      else
        echo "unexpected arg: $1" >&2
        return 1
      fi
      ;;
    esac
  done
  name=$(sanitize "$name")
  [[ -n $name ]] || {
    echo "usage: dev-machine ssh <name> [--recover]" >&2
    return 1
  }
  local statedir="$STATE/$name"
  [[ -d $statedir ]] || {
    echo "no such dev machine: $name" >&2
    return 1
  }
  dm_login || return 1

  # --recover: the in-VM devpod agent/container is gone — typically after
  # the VM crashed and runStrategy=Always booted a fresh one (the scratch
  # Podman storage is an emptyDisk, so it comes back blank). `devpod up`
  # on the existing workspace id re-runs the agent and rebuilds the
  # devcontainer over the (re-established) tunnel, which is what gets the
  # `devpod ssh` below working again. NOTE: the rebuilt container is fresh,
  # so the cc Forgejo token injected by `up` is gone — re-run `dev-machine up`
  # if you need to push again; --recover just
  # gets you a working shell back.
  if [[ $recover -eq 1 ]]; then
    echo "==> --recover: restarting the devcontainer agent (devpod up)"
    load_agents_dotfiles_state "$statedir"
    devpod_up "$name" --provider "dm-$name" --ide none || {
      echo "recover failed — the VM itself may be down/looping." >&2
      echo "check 'dev-machine list' and 'dev-machine console $name'." >&2
      return 1
    }
  fi
  # Lockdown flags: --user agent forces the in-container account even on
  # DevPod versions/configs that would otherwise default an interactive
  # SSH session to root. --start-services=false stops devpod proxying the
  # operator's git/registry credentials into the session, and
  # --agent-forwarding=false stops forwarding the operator's SSH agent in
  # (devpod defaults it ON) — the injected cc token is the sandbox's only
  # Forgejo identity. Disabling agent-forwarding also avoids devpod's noisy teardown
  # error on logout (the forwarded-agent channel closing without a clean
  # exit-status). Trade-off: start-services=false also forgoes devpod
  # port-forwarding; run `devpod ssh <name>` directly if you need that.
  devpod ssh "$name" --user agent --start-services=false --agent-forwarding=false
}

# Recreate just the devcontainer on an already-running VM — the fast
# iteration loop for devcontainer.json / dev-image changes, WITHOUT the
# multi-minute VM create+boot of a full `down`/`up`. `devpod up --recreate`
# tears the container down and rebuilds it over the existing tunnel; the VM,
# its scratch disk, and the local state all survive. A recreate produces a
# fresh container, so the injected Forgejo and Woodpecker credentials are gone.
# Re-inject them from operator-side token files so the refreshed container can
# push and inspect CI immediately.
cmd_refresh() {
  local name="" woodpecker_api_token=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -*)
      echo "unknown flag: $1" >&2
      return 1
      ;;
    *)
      if [[ -z $name ]]; then
        name="$1"
        shift
      else
        echo "unexpected arg: $1" >&2
        return 1
      fi
      ;;
    esac
  done
  name=$(sanitize "$name")
  [[ -n $name ]] || {
    echo "usage: dev-machine refresh <name>" >&2
    return 1
  }
  local statedir="$STATE/$name"
  local host
  [[ -d $statedir ]] || {
    echo "no such dev machine: $name" >&2
    return 1
  }
  dm_login || return 1
  host=$(host_for_machine "$name") || {
    echo "cannot resolve $name's slot; was it created by 'dev-machine up'?" >&2
    return 1
  }
  load_agents_dotfiles_state "$statedir"

  # devpod talks straight to the slot host via the provider pinned at `up`
  # (D.6 — no port-forward to re-establish).
  echo "==> recreating the devcontainer (devpod up --recreate; VM untouched)"
  devpod_up "$name" --provider "dm-$name" --ide none --recreate || {
    echo "refresh failed; inspect with 'dev-machine list' / 'dev-machine console $name'." >&2
    return 1
  }
  if [[ -f "$statedir/repo" ]]; then
    local token="" repo=""
    repo=$(cat "$statedir/repo" 2>/dev/null || true)
    if token=$(forgejo_token 2>/dev/null); then
      echo "==> re-injecting the scoped Forgejo credentials"
      inject_forgejo_credential "$name" "$token" "$repo" "$host" ||
        echo "warning: credential re-injection failed; re-run 'dev-machine up' to restore it" >&2
    else
      echo "warning: no Forgejo token; scoped credentials not re-injected" >&2
      echo "         re-run 'dev-machine up' after fixing forgejoTokenFile" >&2
    fi
  fi
  if woodpecker_api_token=$(woodpecker_token 2>/dev/null); then
    echo "==> re-injecting the Woodpecker API credential"
    inject_woodpecker_credential "$woodpecker_api_token" "$host" ||
      echo "warning: Woodpecker credential re-injection failed; re-run 'dev-machine up' to restore it" >&2
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
  name=$(sanitize "${1:-}")
  [[ -n $name ]] || {
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
    --no-revive)
      revive=0
      shift
      ;;
    -*)
      echo "unknown flag: $1" >&2
      return 1
      ;;
    *)
      if [[ -z $name ]]; then
        name="$1"
        shift
      else
        echo "unexpected arg: $1" >&2
        return 1
      fi
      ;;
    esac
  done
  name=$(sanitize "$name")
  [[ -n $name ]] || {
    echo "usage: dev-machine rescue <name> [--no-revive]" >&2
    return 1
  }
  local statedir="$STATE/$name"
  [[ -d $statedir ]] || {
    echo "no such dev machine: $name" >&2
    return 1
  }
  load_agents_dotfiles_state "$statedir"
  dm_login || return 1

  # ── Stage 0: assess — and diagnose honestly when work can't be saved ──
  # --ignore-not-found makes "VMI absent" an empty string with exit 0, so a
  # genuine cluster/auth error (any other non-zero) still aborts under set
  # -e with kubectl's own message — rather than being misreported as "the
  # VM is gone".
  local vm="dm-$name" cur_uid rec_uid phase
  cur_uid=$(kubectl get vmi "$vm" -n "$NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.uid}')
  if [[ -z $cur_uid ]]; then
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
  if [[ -n $rec_uid && $rec_uid != "$cur_uid" ]]; then
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
  if [[ $phase != "Running" ]]; then
    echo "VMI $vm phase is '$phase' (not Running); cannot reach the guest yet." >&2
    echo "retry once it is Running, or inspect with 'dev-machine console $name'." >&2
    return 1
  fi

  # ── Stage 1: VM sshd reachable → extract over the OOM-protected sshd ───
  # Direct SSH to the slot host (D.6); the slot is recorded at `up` time.
  local slot host
  slot=$(cat "$statedir/slot" 2>/dev/null) || slot=$(slot_of_vm "$name")
  [[ -n $slot ]] || {
    echo "cannot resolve $name's slot; was it created by 'dev-machine up'?" >&2
    return 1
  }
  host=$(host_for_slot "$slot")

  echo "==> probing VM sshd on $host"
  local reachable=0 _
  for _ in $(seq 1 10); do
    if ssh_dev "$host" true 2>/dev/null; then
      reachable=1
      break
    fi
    sleep 2
  done
  if [[ $reachable -ne 1 ]]; then
    # VM is Running but its sshd is unreachable (rare — sshd is
    # OOM-protected). Fall back to a manual recover/pull over the
    # serial console.
    echo "VM sshd is unreachable, though the VM is Running (rare — sshd is" >&2
    echo "OOM-protected). Recover/extract manually over the serial console:" >&2
    echo "  dev-machine console $name      # root autologin, then e.g.:" >&2
    echo "  #   podman ps; podman start <id>" >&2
    echo "  #   podman cp <id>:/workspaces/$name /root/$name-rescue" >&2
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
  rescue_backup "$name" "$host" "$rescuedir" && backed_up=1

  # --no-revive: stop here; the caller only wanted the data out.
  if [[ $revive -eq 0 ]]; then
    if [[ $backed_up -eq 1 ]]; then
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
  if ! devpod_up "$name" --provider "dm-$name" --ide none; then
    echo >&2
    echo "could not restore a working devcontainer." >&2
    if [[ $backed_up -eq 1 ]]; then
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
  # no-op'd (the container had been stopped, so Podman couldn't read it).
  if [[ $backed_up -eq 0 ]]; then
    echo "==> backing up the working tree (post-recovery safety net)"
    rescue_backup "$name" "$host" "$rescuedir" && backed_up=1
  fi

  echo
  echo "dev machine '$name' recovered. Connect with:  dev-machine ssh $name"
  if [[ $backed_up -eq 1 ]]; then
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
    --no-agent)
      no_agent=1
      shift
      ;;
    -*)
      echo "unknown flag: $1" >&2
      return 1
      ;;
    *)
      if [[ -z $name ]]; then
        name="$1"
        shift
      else
        echo "unexpected arg: $1" >&2
        return 1
      fi
      ;;
    esac
  done
  name=$(sanitize "$name")
  [[ -n $name ]] || {
    echo "usage: dev-machine down <name> [--no-agent]" >&2
    return 1
  }
  local statedir="$STATE/$name"
  dm_login || return 1

  echo "==> tearing down $name"
  # Deleting the VM frees its slot (the next `up` sees the slot label gone
  # via occupied_slots). `devpod delete` normally SSHes into the VM to run
  # the in-container agent teardown. When the VM has crashed/OOM-killed that
  # session is dead, and the call blocks on the unreachable agent — which is
  # why ordinary `down` wedges. --no-agent skips the in-VM teardown: we drop
  # the VM + secret FIRST (the container dies with the VM regardless, so the
  # agent teardown is moot), which makes the SSH target provably gone, then
  # `devpod delete --force` only has to clear devpod's local bookkeeping
  # (connection refused → fast fail → --force removes local state). The
  # `timeout` is a backstop so a wedged devpod can never re-hang `down`.
  if [[ $no_agent -eq 1 ]]; then
    echo "    (--no-agent: skipping in-VM devpod teardown)"
    kubectl delete vm "dm-$name" -n "$NAMESPACE" --ignore-not-found
    kubectl delete secret "dm-$name-ssh-key" -n "$NAMESPACE" --ignore-not-found
    timeout 30 devpod delete "$name" --force 2>/dev/null || true
  else
    devpod delete "$name" --force 2>/dev/null || true
    kubectl delete vm "dm-$name" -n "$NAMESPACE" --ignore-not-found
    kubectl delete secret "dm-$name-ssh-key" -n "$NAMESPACE" --ignore-not-found
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

  dev-machine up [<repo>] [--name N] [--repo owner/name] [--rebuild] [--no-push-cred] [--memory 8Gi] [--cpu 4] [--disk 60Gi]
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

cmd="${1:-}"
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
*)
  echo "unknown command: $cmd" >&2
  usage
  exit 1
  ;;
esac
