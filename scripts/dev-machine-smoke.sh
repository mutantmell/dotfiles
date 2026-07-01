#!/usr/bin/env bash
set -euo pipefail

failures=0
skips=0
network=0
repo_root=""

usage() {
  cat >&2 <<'EOF'
usage: ./scripts/dev-machine-smoke.sh [--network]

  --network  also probe the expected dev-machine egress shape:
             WAN HTTPS and forgejo.internal SSH/HTTPS are reachable, while
             non-creil internal service egress is blocked.
             This is skipped by default so the smoke test remains useful in
             nested command sandboxes that mask DNS or network access.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --network)
    network=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    usage
    exit 2
    ;;
  esac
done

in_codex_command_sandbox() {
  [[ -n ${CODEX_THREAD_ID:-} ]] && grep -q '[[:space:]]/tmp/\.codex[[:space:]]' /proc/self/mountinfo
}

find_repo_root() {
  if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    return 0
  fi

  if [[ -d /workspaces/dotfiles/.git ]]; then
    repo_root=/workspaces/dotfiles
    return 0
  fi

  return 1
}

check() {
  local name=$1
  shift
  echo "==> $name"
  if "$@"; then
    echo "  PASS $name"
  else
    echo "  FAIL $name" >&2
    failures=$((failures + 1))
  fi
}

check_absent() {
  local name=$1
  shift
  echo "==> $name"
  if "$@"; then
    echo "  FAIL $name" >&2
    failures=$((failures + 1))
  else
    echo "  PASS $name"
  fi
}

diagnose() {
  local name=$1
  shift
  echo "    $name: $*" >&2
}

skip() {
  local name=$1
  local reason=$2
  echo "==> $name"
  echo "  SKIP $name ($reason)"
  skips=$((skips + 1))
}

tcp_connect() {
  local host=$1 port=$2
  timeout 5 bash -c ":</dev/tcp/$host/$port" >/dev/null 2>&1
}

agent_user_is_non_root() {
  [[ $(id -u) != 0 && $(id -un) == agent ]]
}

agent_home_matches_passwd() {
  [[ $HOME == /home/agent ]] && grep -qx "agent:x:1000:1000:agent:/home/agent:/bin/bash" /etc/passwd
}

devcontainer_pins_agent_user() {
  [[ -f "$repo_root/.devcontainer/devcontainer.json" ]] &&
    grep -Eq '^[[:space:]]*"containerUser"[[:space:]]*:[[:space:]]*"agent"' "$repo_root/.devcontainer/devcontainer.json" &&
    grep -Eq '^[[:space:]]*"remoteUser"[[:space:]]*:[[:space:]]*"agent"' "$repo_root/.devcontainer/devcontainer.json" &&
    grep -Eq '^[[:space:]]*"updateRemoteUserUID"[[:space:]]*:[[:space:]]*false' "$repo_root/.devcontainer/devcontainer.json"
}

ssh_uses_agent_home() {
  local ssh_config

  [[ $(id -u) != 0 && $(id -un) == agent && $HOME == /home/agent ]] || return 1

  ssh_config=$(ssh -G forgejo.internal 2>/dev/null) || return 1
  ! grep -Eq '^userknownhostsfile .*/root/\.ssh/.*$' <<<"$ssh_config" || return 1
  grep -qx 'userknownhostsfile /home/agent/.ssh/known_hosts /home/agent/.ssh/known_hosts2' <<<"$ssh_config" || return 1

  ! grep -qx 'identityfile ~/.ssh/dm_deploy_key' <<<"$ssh_config" || return 1
}

devcontainer_configures_cgroups() {
  [[ -f "$repo_root/.devcontainer/devcontainer.json" ]] &&
    grep -Eq '^[[:space:]]*"--cgroupns=host",?$' "$repo_root/.devcontainer/devcontainer.json" &&
    grep -Eq '^[[:space:]]*"--mount=type=bind,source=/sys/fs/cgroup,target=/sys/fs/cgroup",?$' "$repo_root/.devcontainer/devcontainer.json"
}

devcontainer_uses_host_nix() {
  [[ -f "$repo_root/.devcontainer/devcontainer.json" ]] &&
    grep -Eq '"--mount=type=bind,source=/nix,target=/nix"' "$repo_root/.devcontainer/devcontainer.json"
}

mountinfo_matches() {
  local mountpoint=$1 source=$2 fstype=$3
  awk -v mountpoint="$mountpoint" -v source="$source" -v fstype="$fstype" '
    $5 != mountpoint { next }
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "-") {
          if ($(i + 1) == fstype && $(i + 2) == source) {
            found = 1
          }
          break
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' /proc/self/mountinfo
}

cgroup_mount_is_rw() {
  awk '$5 == "/sys/fs/cgroup" && $6 ~ /(^|,)rw(,|$)/ { found = 1 } END { exit found ? 0 : 1 }' /proc/self/mountinfo
}

cgroup_mount_is_v2() {
  mountinfo_matches /sys/fs/cgroup cgroup2 cgroup2
}

cgroup_namespace_is_host_visible() {
  ! grep -qx '0::/' /proc/self/cgroup
}

cgroup_mount_matches_namespace() {
  awk '$5 == "/sys/fs/cgroup" && $4 !~ /^\/\.\./ { found = 1 } END { exit found ? 0 : 1 }' /proc/self/mountinfo
}

nix_daemon_has_cap_sys_admin() {
  local pid cap_hex cap
  pid=$(ps -eo pid,user,args | awk '$2 == "root" && $3 == "nix" && $4 == "daemon" { print $1; exit }')
  [[ -n $pid ]] || return 1
  cap_hex=$(sed -n 's/^CapEff:[[:space:]]*//p' "/proc/$pid/status")
  [[ -n $cap_hex ]] || return 1
  cap=$((16#$cap_hex))
  ((cap & (1 << 21)))
}

nix_config_contains_word() {
  local key=$1 word=$2
  nix config show "$key" 2>/dev/null | grep -Eq "(^|[[:space:]])$word([[:space:]]|$)"
}

no_local_nix_daemon_process() {
  ! ps -eo user,args | awk '$1 == "root" && $2 == "nix" && $3 == "daemon" { found = 1 } END { exit found ? 0 : 1 }'
}

dev_machine_image_configures_scratch_build_dir() {
  [[ -f "$repo_root/packages/dev-machine-image/configuration.nix" ]] || return 1

  nix eval --impure --raw --expr \
    "(import <nixpkgs/nixos> { system = \"x86_64-linux\"; configuration = import $repo_root/packages/dev-machine-image/configuration.nix; }).config.nix.settings.build-dir" \
    2>/dev/null | grep -qx "/mnt/scratch/nix-builds"
}

tea_config_dir_is_private() {
  local path=${TEA_CONFIG_HOME:-$HOME/.config/tea}
  [[ -d $path ]] || return 1
  [[ $(stat -c %a "$path") == 700 ]] || return 1
  [[ $(stat -c %U "$path") == "$(id -un)" ]] || return 1
}

check "repo root detected" find_repo_root
diagnose "repo root" "${repo_root:-not found}"
check "agent user is non-root" agent_user_is_non_root
check "agent HOME matches passwd" agent_home_matches_passwd
check "SSH uses agent home" ssh_uses_agent_home
check "devcontainer pins agent user without UID rewrite" devcontainer_pins_agent_user
check_absent "devcontainer does not configure host cgroups" devcontainer_configures_cgroups
check "devcontainer bind-mounts host Nix store" devcontainer_uses_host_nix
check "devcontainer has no local nix-daemon bootstrap" no_local_nix_daemon_process

check "NIX_REMOTE uses daemon" test "${NIX_REMOTE:-}" = daemon
check "Nix daemon responds" nix store info --store daemon
check "Nix build users group configured" bash -c 'nix config show build-users-group 2>/dev/null | grep -qx "nixbld"'
check "Nix allows host dev user" nix_config_contains_word allowed-users dev
check_absent "Nix does not trust host dev user" nix_config_contains_word trusted-users dev
check_absent "agent cannot write directly to /nix/store" test -w /nix/store
check "Nix tree was migrated to scratch" test -e /nix/.dev-machine-nix-seeded
check "dev-machine image configures scratch Nix build dir" dev_machine_image_configures_scratch_build_dir
check "Nix auto-allocates build UIDs" bash -c 'nix config show auto-allocate-uids 2>/dev/null | grep -qx "true"'
check "Nix has auto-allocate-uids feature" nix_config_contains_word experimental-features auto-allocate-uids
check "Nix cgroups enabled" bash -c 'nix config show use-cgroups 2>/dev/null | grep -qx "true"'
check "Nix advertises uid-range" nix_config_contains_word system-features uid-range

for wrapper in agent-fmt agent-preflight agent-preflight-quick agent-preflight-full agent-checks agent-build-check agent-smoke agent-pr-status agent-pr-comments agent-pr-comment; do
  check "$wrapper available" command -v "$wrapper"
done

check "su available for DevPod user switching" command -v su
if [[ $(id -u) == 0 ]]; then
  # shellcheck disable=SC2016
  check "su switches to agent without PAM" bash -c '[[ $(su -c "id -un" agent) == agent ]]'
else
  skip "su switches to agent without PAM" "requires root"
fi

if ! command -v bwrap >/dev/null 2>&1; then
  skip "bubblewrap pivot_root sandbox" "bwrap is not installed in this environment"
elif in_codex_command_sandbox; then
  skip "bubblewrap pivot_root sandbox" "masked by Codex's nested command sandbox"
else
  check "bubblewrap pivot_root sandbox" bwrap --ro-bind / / true
fi

# shellcheck disable=SC2016
if in_codex_command_sandbox; then
  skip "Nix sandbox build" "masked by Codex's nested command sandbox"
  skip "Nix uid-range sandbox build" "masked by Codex's nested command sandbox"
  skip "cgroup mount is writable for daemon" "masked by Codex's nested command sandbox"
else
  diagnose "/proc/self/cgroup" "$(tr '\n' ';' </proc/self/cgroup)"
  diagnose "/sys mount" "$(awk '$5 == "/sys" { print }' /proc/self/mountinfo)"
  diagnose "/sys/fs/cgroup mount" "$(awk '$5 == "/sys/fs/cgroup" { print }' /proc/self/mountinfo)"
  diagnose "/nix mount" "$(awk '$5 == "/nix" { print }' /proc/self/mountinfo)"
  check "Nix sandbox build" nix build --impure --expr 'with import <nixpkgs> {}; runCommand "dev-machine-smoke" {} "echo ok > $out"' --no-link
  check "Nix uid-range sandbox build" nix build --impure --expr 'with import <nixpkgs> {}; runCommand "dev-machine-uid-range-smoke" { requiredSystemFeatures = [ "uid-range" ]; } "echo ok > $out"' --no-link
fi

check "Nix sandbox enabled" bash -c 'nix config show sandbox 2>/dev/null | grep -qx "true"'
check "Nix sandbox fallback disabled" bash -c 'nix config show sandbox-fallback 2>/dev/null | grep -qx "false"'
check "seccomp active" bash -c 'grep -q "^Seccomp:[[:space:]]*2$" /proc/self/status'
if in_codex_command_sandbox; then
  skip "/dev/kvm available" "masked by Codex's nested command sandbox"
else
  check "/dev/kvm available" test -e /dev/kvm
fi

for tool in curl wget python3 fd just findmnt ip dig nc ps rsync unzip zstd file which make pkg-config tea; do
  check "$tool available" command -v "$tool"
done

for tool in kubectl docker podman devpod virtctl gh; do
  check_absent "$tool absent from agent PATH" command -v "$tool"
done

check "tea reports a version" tea --version
check "tea config directory is private" tea_config_dir_is_private

check_absent "docker socket absent" test -S /var/run/docker.sock
check_absent "podman socket absent" test -S /run/podman/podman.sock
check_absent "KUBECONFIG env absent" printenv KUBECONFIG
check_absent "kube config absent" test -e "$HOME/.kube/config"
check_absent "docker registry credentials absent" test -e "$HOME/.docker/config.json"
check_absent "podman registry credentials absent" test -e "$HOME/.config/containers/auth.json"
check_absent "operator SSH agent absent" printenv SSH_AUTH_SOCK

if tea whoami >/dev/null 2>&1; then
  check "Forgejo tea login configured" tea whoami
  check "Forgejo git credential file permissions" test "$(stat -c %a "$HOME/.config/tea/git-credentials")" = 600
else
  skip "Forgejo tea login configured" "no Forgejo API credential was provisioned"
  skip "Forgejo git credential file permissions" "no Forgejo API credential was provisioned"
fi

if [[ -f "$HOME/.config/woodpecker/token" ]]; then
  check "Woodpecker token file permissions" test "$(stat -c %a "$HOME/.config/woodpecker/token")" = 600
  check "Woodpecker env file permissions" test "$(stat -c %a "$HOME/.config/woodpecker/env")" = 600
  # shellcheck disable=SC2016
  check "Woodpecker server exported by env file" bash -c '. "$HOME/.config/woodpecker/env"; test "$WOODPECKER_SERVER" = "https://woodpecker.internal"'
  # shellcheck disable=SC2016
  check "Woodpecker token exported by env file" bash -c '. "$HOME/.config/woodpecker/env"; test -n "$WOODPECKER_TOKEN"'
else
  skip "Woodpecker token file permissions" "no Woodpecker API credential was provisioned"
  skip "Woodpecker env file permissions" "no Woodpecker API credential was provisioned"
  skip "Woodpecker server exported by env file" "no Woodpecker API credential was provisioned"
  skip "Woodpecker token exported by env file" "no Woodpecker API credential was provisioned"
fi

if [[ $network -eq 1 ]]; then
  if in_codex_command_sandbox; then
    skip "network egress probes" "masked by Codex's nested command sandbox"
  else
    check "WAN HTTPS egress" tcp_connect example.com 443
    check "forgejo SSH egress" tcp_connect forgejo.internal 22
    check "forgejo HTTPS egress" tcp_connect forgejo.internal 443
    check_absent "non-creil internal HTTPS egress blocked" tcp_connect zeiss.internal 443
  fi
else
  skip "network egress probes" "pass --network to test WAN + forgejo.internal reachability and non-creil internal blocking"
fi

if [[ $failures -gt 0 ]]; then
  echo "dev-machine smoke test failed: $failures check(s) failed" >&2
  exit 1
fi

if [[ $skips -gt 0 ]]; then
  echo "dev-machine smoke test passed with $skips skipped check(s)"
else
  echo "dev-machine smoke test passed"
fi
