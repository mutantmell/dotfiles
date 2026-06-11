#!/usr/bin/env bash
set -euo pipefail

failures=0
skips=0
network=0

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

nix_config_contains_word() {
  local key=$1 word=$2
  nix config show "$key" 2>/dev/null | grep -Eq "(^|[[:space:]])$word([[:space:]]|$)"
}

check "agent user is non-root" agent_user_is_non_root
check "agent HOME matches passwd" agent_home_matches_passwd

check "NIX_REMOTE uses daemon" test "${NIX_REMOTE:-}" = daemon
check "Nix daemon responds" nix store info --store daemon
check "Nix build users group configured" bash -c 'nix config show build-users-group 2>/dev/null | grep -qx "nixbld"'
check "Nix allows agent user" nix_config_contains_word allowed-users agent
check_absent "Nix does not trust agent user" nix_config_contains_word trusted-users agent
check_absent "agent cannot write directly to /nix/store" test -w /nix/store

for wrapper in agent-fmt agent-preflight agent-preflight-quick agent-preflight-full agent-checks agent-build-check agent-smoke; do
  check "$wrapper available" command -v "$wrapper"
done

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
else
  check "Nix sandbox build" nix build --impure --expr 'with import <nixpkgs> {}; runCommand "dev-machine-smoke" {} "echo ok > $out"' --no-link
fi

check "Nix sandbox enabled" bash -c 'nix config show sandbox 2>/dev/null | grep -qx "true"'
check "seccomp active" bash -c 'grep -q "^Seccomp:[[:space:]]*2$" /proc/self/status'
# shellcheck disable=SC2016
check "CAP_SYS_ADMIN present" bash -c 'cap_hex=$(sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status); cap=$((16#$cap_hex)); (( cap & (1 << 21) ))'
if in_codex_command_sandbox; then
  skip "/dev/kvm available" "masked by Codex's nested command sandbox"
else
  check "/dev/kvm available" test -e /dev/kvm
fi

for tool in kubectl docker devpod virtctl gh tea; do
  check_absent "$tool absent from agent PATH" command -v "$tool"
done

check_absent "docker socket absent" test -S /var/run/docker.sock
check_absent "KUBECONFIG env absent" printenv KUBECONFIG
check_absent "kube config absent" test -e "$HOME/.kube/config"
check_absent "docker registry credentials absent" test -e "$HOME/.docker/config.json"
check_absent "operator SSH agent absent" printenv SSH_AUTH_SOCK

if [[ -f "$HOME/.ssh/dm_deploy_key" ]]; then
  check "Forgejo deploy key permissions" test "$(stat -c %a "$HOME/.ssh/dm_deploy_key")" = 600
  check "Forgejo SSH config pins deploy key" bash -c 'ssh -G forgejo.internal 2>/dev/null | grep -qx "identityfile ~/.ssh/dm_deploy_key"'
  check "Forgejo SSH config disables extra identities" bash -c 'ssh -G forgejo.internal 2>/dev/null | grep -qx "identitiesonly yes"'
else
  skip "Forgejo deploy key present" "no per-session push credential was provisioned"
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
