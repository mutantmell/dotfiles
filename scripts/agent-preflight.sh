#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: ./scripts/agent-preflight.sh [--quick|--full] [check ...]

Agent-friendly validation entrypoint.

  --quick   Format, then run a small set of cheap/high-signal checks.
  --full    Format, then run the full run-checks.sh suite.
  check ... With explicit check names, format then run those checks.

This intentionally avoids `nix flake check`: this flake has many NixOS
evaluations, and a single evaluator process can be OOM-killed. The run-checks
wrapper executes checks as separate `nix build` invocations.
USAGE
}

mode=quick
checks=()

while [[ $# -gt 0 ]]; do
  case "$1" in
  --quick)
    mode=quick
    shift
    ;;
  --full)
    mode=full
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "unknown flag: $1" >&2
    usage
    exit 2
    ;;
  *)
    checks+=("$1")
    shift
    ;;
  esac
done

if [[ $# -gt 0 ]]; then
  checks+=("$@")
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

echo "==> formatting"
nix fmt

if [[ ${#checks[@]} -gt 0 ]]; then
  echo "==> running explicit checks: ${checks[*]}"
  exec "$script_dir/run-checks.sh" "${checks[@]}"
fi

case "$mode" in
quick)
  quick_checks=(
    formatting
    network-registry
    router6-assertions
    router6-firewall-properties
    router6-zone-system
    openwrt-config
    disko-vmtools-canary
  )
  echo "==> running quick checks: ${quick_checks[*]}"
  exec "$script_dir/run-checks.sh" "${quick_checks[@]}"
  ;;
full)
  echo "==> running full check suite"
  exec "$script_dir/run-checks.sh"
  ;;
*)
  echo "internal error: unknown mode $mode" >&2
  exit 2
  ;;
esac
