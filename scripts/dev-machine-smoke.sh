#!/usr/bin/env bash
set -euo pipefail

failures=0
skips=0

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

skip() {
  local name=$1
  local reason=$2
  echo "==> $name"
  echo "  SKIP $name ($reason)"
  skips=$((skips + 1))
}

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

if [[ $failures -gt 0 ]]; then
  echo "dev-machine smoke test failed: $failures check(s) failed" >&2
  exit 1
fi

if [[ $skips -gt 0 ]]; then
  echo "dev-machine smoke test passed with $skips skipped check(s)"
else
  echo "dev-machine smoke test passed"
fi
