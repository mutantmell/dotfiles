#!/usr/bin/env bash
set -euo pipefail

# Run flake checks in separate nix processes to avoid OOM.
#
# `nix flake check` evaluates all outputs (nixosConfigurations, checks,
# packages) in a single process. This flake has ~66 NixOS module evaluations
# (4 hosts, 16 microvm guests, 2 incus guests, 42 test nodes, deploy-rs)
# which can exceed 23GB RSS and get OOM-killed.
#
# This script runs each check as a separate `nix build` invocation so
# memory is bounded per-check rather than accumulated.
#
# Usage:
#   ./scripts/run-checks.sh              # run all checks
#   ./scripts/run-checks.sh -j4          # run up to 4 checks in parallel
#   ./scripts/run-checks.sh <name> ...   # run specific checks

SYSTEM="x86_64-linux"
FLAKE_REF="."
MAX_PARALLEL=1
CHECKS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
  -j*)
    MAX_PARALLEL="${1#-j}"
    shift
    ;;
  *)
    CHECKS+=("$1")
    shift
    ;;
  esac
done

# If no checks specified, discover all available checks
if [[ ${#CHECKS[@]} -eq 0 ]]; then
  echo "Discovering checks..."
  CHECKS_JSON=$(nix eval "${FLAKE_REF}#checks.${SYSTEM}" --apply 'x: builtins.attrNames x' --json 2>/dev/null)
  mapfile -t CHECKS < <(echo "$CHECKS_JSON" | sed 's/[][]//g; s/,/\n/g; s/"//g; s/ //g' | grep -v '^$')
fi

# Per-test logs are captured here. Kept on failure so a flake or real error
# can be diagnosed after the fact (the script no longer discards `nix build`
# output). Passing tests have their log file deleted to keep the dir tidy.
LOG_DIR="$(mktemp -d -t run-checks-XXXXXX)"
echo "Per-test logs: ${LOG_DIR}"
echo ""

PASSED=0
FAILED=0
FAILED_NAMES=()

TOTAL=${#CHECKS[@]}
echo "Running ${TOTAL} nix checks (parallelism: ${MAX_PARALLEL})..."
echo ""

if [[ $MAX_PARALLEL -le 1 ]]; then
  # Sequential mode — simple and clear
  for check in "${CHECKS[@]}"; do
    log="${LOG_DIR}/${check}.log"
    if nix build "${FLAKE_REF}#checks.${SYSTEM}.${check}" --print-build-logs >"$log" 2>&1; then
      echo "  PASS  ${check}"
      rm -f "$log"
      PASSED=$((PASSED + 1))
    else
      echo "  FAIL  ${check}  (log: ${log})"
      FAILED=$((FAILED + 1))
      FAILED_NAMES+=("${check}")
    fi
  done
else
  # Parallel mode — run up to MAX_PARALLEL at once
  declare -A PID_TO_NAME
  declare -A PID_TO_LOG
  RUNNING=0

  reap_one() {
    # Wait for any child to finish
    local pid
    wait -n -p pid 2>/dev/null || true
    if [[ -n ${PID_TO_NAME[$pid]+x} ]]; then
      local name="${PID_TO_NAME[$pid]}"
      local log="${PID_TO_LOG[$pid]}"
      if wait "$pid" 2>/dev/null; then
        echo "  PASS  ${name}"
        rm -f "$log"
        PASSED=$((PASSED + 1))
      else
        echo "  FAIL  ${name}  (log: ${log})"
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("${name}")
      fi
      unset "PID_TO_NAME[$pid]"
      unset "PID_TO_LOG[$pid]"
      RUNNING=$((RUNNING - 1))
    fi
  }

  for check in "${CHECKS[@]}"; do
    while [[ $RUNNING -ge $MAX_PARALLEL ]]; do
      reap_one
    done
    log="${LOG_DIR}/${check}.log"
    nix build "${FLAKE_REF}#checks.${SYSTEM}.${check}" --print-build-logs >"$log" 2>&1 &
    PID_TO_NAME[$!]="$check"
    PID_TO_LOG[$!]="$log"
    RUNNING=$((RUNNING + 1))
  done

  # Wait for remaining
  while [[ $RUNNING -gt 0 ]]; do
    reap_one
  done
fi

# Tidy up an empty log dir on full success so we don't litter /tmp.
rmdir "$LOG_DIR" 2>/dev/null || true

echo ""
echo "Results: ${PASSED} passed, ${FAILED} failed (${TOTAL} total)"

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "Failed checks:"
  for name in "${FAILED_NAMES[@]}"; do
    echo "  - $name"
  done
  echo ""
  echo "Re-run a failing check with build logs:"
  echo "  nix build .#checks.${SYSTEM}.<name> --print-build-logs"
  exit 1
fi
