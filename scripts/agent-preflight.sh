#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: ./scripts/agent-preflight.sh [--quick|--full] [check ...]

Agent-friendly validation entrypoint.

  --quick   Check formatting, then run cheap/high-signal checks.
  --full    Run the full run-checks.sh suite, including formatting.
  --summary-dir DIR
            Write check-summary.json into DIR.
  check ... Check formatting, then run those explicit checks.

This intentionally avoids `nix flake check`: this flake has many NixOS
evaluations, and a single evaluator process can be OOM-killed. The run-checks
wrapper executes checks as separate `nix build` invocations.
USAGE
}

mode=quick
summary_dir="${CHECK_SUMMARY_DIR:-}"
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
  --summary-dir)
    shift
    [[ $# -gt 0 ]] || {
      echo "--summary-dir requires a directory" >&2
      usage
      exit 2
    }
    summary_dir="$1"
    shift
    ;;
  --summary-dir=*)
    summary_dir="${1#--summary-dir=}"
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

run_checks_args=()
if [[ -n $summary_dir ]]; then
  run_checks_args+=(--summary-dir "$summary_dir")
fi

if [[ ${#checks[@]} -gt 0 ]]; then
  explicit_checks=(formatting)
  for check in "${checks[@]}"; do
    if [[ $check != formatting ]]; then
      explicit_checks+=("$check")
    fi
  done
  echo "==> running explicit checks: ${explicit_checks[*]}"
  exec "$script_dir/run-checks.sh" "${run_checks_args[@]}" "${explicit_checks[@]}"
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
  # These checks throw during eval on failure. In CI they run under gVisor, where
  # uncached trivial Nix builders can fail while initializing the build env.
  exec "$script_dir/run-checks.sh" "${run_checks_args[@]}" --eval-only-pure "${quick_checks[@]}"
  ;;
full)
  echo "==> running full check suite"
  exec "$script_dir/run-checks.sh" "${run_checks_args[@]}"
  ;;
*)
  echo "internal error: unknown mode $mode" >&2
  exit 2
  ;;
esac
