#!/usr/bin/env bash
set -euo pipefail

failures=0

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

check "bubblewrap pivot_root sandbox" bwrap --ro-bind / / true
# shellcheck disable=SC2016
check "Nix sandbox build" nix build --impure --expr 'with import <nixpkgs> {}; runCommand "dev-machine-smoke" {} "echo ok > $out"' --no-link

check "Nix sandbox enabled" bash -c 'nix config show sandbox 2>/dev/null | grep -qx "true"'
check "seccomp active" bash -c 'grep -q "^Seccomp:[[:space:]]*2$" /proc/self/status'
# shellcheck disable=SC2016
check "CAP_SYS_ADMIN present" bash -c 'cap_hex=$(sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status); cap=$((16#$cap_hex)); (( cap & (1 << 21) ))'
check "/dev/kvm available" test -e /dev/kvm

if [[ $failures -gt 0 ]]; then
  echo "dev-machine smoke test failed: $failures check(s) failed" >&2
  exit 1
fi

echo "dev-machine smoke test passed"
