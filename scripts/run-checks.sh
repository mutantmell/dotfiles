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
#   ./scripts/run-checks.sh --shard 1/4  # run a stable shard of all checks
#   ./scripts/run-checks.sh --summary-dir ci-summary <name> ...
#   ./scripts/run-checks.sh <name> ...   # run specific checks
#   ./scripts/run-checks.sh --eval-only-pure <name> ...

SYSTEM="x86_64-linux"
FLAKE_REF="."
MAX_PARALLEL=1
EVAL_ONLY_PURE=0
SHARD_SPEC=""
SUMMARY_DIR="${CHECK_SUMMARY_DIR:-}"
CHECKS=()

declare -A PURE_EVAL_CHECKS=(
  ["network-registry"]=1
  ["router6-assertions"]=1
  ["router6-firewall-properties"]=1
  ["router6-zone-system"]=1
  ["openwrt-config"]=1
  ["disko-vmtools-canary"]=1
)

usage() {
  cat <<EOF
Usage: $0 [options] [check ...]

Options:
  -jN, -j N          Run up to N checks in parallel
  --eval-only-pure   Evaluate pure checks to drvPath only
  --shard N/M        Run shard N of M from the selected checks
  --summary-dir DIR  Write check-summary.json into DIR
EOF
}

die() {
  echo "error: $*" >&2
  echo "" >&2
  usage >&2
  exit 2
}

is_positive_int() {
  [[ $1 =~ ^[1-9][0-9]*$ ]]
}

parse_shard_spec() {
  local spec="$1"
  if [[ ! $spec =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]]; then
    die "--shard must use N/M with positive integers"
  fi

  SHARD_INDEX="${BASH_REMATCH[1]}"
  SHARD_TOTAL="${BASH_REMATCH[2]}"
  if ((SHARD_INDEX > SHARD_TOTAL)); then
    die "--shard index must be less than or equal to shard total"
  fi
}

redacted_tail() {
  local log=$1
  local tmp
  if [[ ! -s $log ]]; then
    return 0
  fi

  tmp=$(mktemp -t run-checks-tail-XXXXXX)
  # Keep byte truncation away from the pipe. With pipefail enabled, `head -c`
  # can otherwise SIGPIPE upstream commands and abort summary generation.
  tail -n 160 "$log" |
    sed -E \
      -e 's/((TOKEN|SECRET|PASSWORD|PASS|KEY)[A-Za-z0-9_]*=)[^[:space:]]+/\1[REDACTED]/gI' \
      -e 's/([A-Za-z_][A-Za-z0-9_]*_(TOKEN|SECRET|PASSWORD|PASS|KEY)[A-Za-z0-9_]*=)[^[:space:]]+/\1[REDACTED]/gI' \
      -e 's/(Authorization:[[:space:]]*(Bearer|token)[[:space:]]+)[^[:space:]]+/\1[REDACTED]/gI' \
      -e 's#(https?://[^[:space:]@]+:)[^[:space:]@]+@#\1[REDACTED]@#g' >"$tmp"
  head -c 20000 "$tmp"
  rm -f "$tmp"
}

write_summary() {
  local dir=$1 status_file=$2
  local head_sha pipeline_url repo pipeline_number workflow step objects_file
  mkdir -p "$dir"

  head_sha="${CI_COMMIT_SHA:-${WOODPECKER_COMMIT_SHA:-}}"
  if [[ -z $head_sha ]]; then
    head_sha=$(git rev-parse HEAD 2>/dev/null || true)
  fi
  pipeline_url="${CI_PIPELINE_URL:-${WOODPECKER_BUILD_LINK:-${WOODPECKER_PIPELINE_URL:-}}}"
  repo="${CI_REPO:-${WOODPECKER_REPO:-${WOODPECKER_REPO_FULL_NAME:-}}}"
  pipeline_number="${CI_PIPELINE_NUMBER:-${WOODPECKER_BUILD_NUMBER:-${WOODPECKER_PIPELINE_NUMBER:-}}}"
  workflow="${CI_WORKFLOW:-${WOODPECKER_WORKFLOW_NAME:-${WOODPECKER_PIPELINE_NAME:-full-checks}}}"
  step="${CI_STEP_NAME:-${WOODPECKER_STEP_NAME:-full-checks}}"

  objects_file=$(mktemp -t run-checks-summary-XXXXXX)
  while IFS=$'\t' read -r name status log_path reproduce; do
    [[ -n $name ]] || continue
    [[ $log_path == "-" ]] && log_path=""
    if [[ $status == "failed" && -n $log_path && -f $log_path ]]; then
      jq -n \
        --arg name "$name" \
        --arg status "$status" \
        --arg reproduce "$reproduce" \
        --rawfile log_tail "$log_path" \
        '{name:$name,status:$status,reproduce:$reproduce,log_url:"",log_tail:$log_tail}' >>"$objects_file"
    else
      jq -n \
        --arg name "$name" \
        --arg status "$status" \
        --arg reproduce "$reproduce" \
        '{name:$name,status:$status,reproduce:$reproduce}' >>"$objects_file"
    fi
  done <"$status_file"

  jq -s \
    --arg schema "dotfiles-ci-summary:v1" \
    --arg head "$head_sha" \
    --arg pipeline_url "$pipeline_url" \
    --arg repo "$repo" \
    --arg pipeline_number "$pipeline_number" \
    --arg workflow "$workflow" \
    --arg step "$step" \
    '{
      schema: $schema,
      head: $head,
      status: (if any(.[]; .status == "failed") then "failed" else "passed" end),
      repository: $repo,
      pipeline_number: $pipeline_number,
      pipeline_url: $pipeline_url,
      workflow: $workflow,
      step: $step,
      checks: .,
      failed_checks: map(select(.status == "failed"))
    }' "$objects_file" >"$dir/check-summary.json"
  rm -f "$objects_file"
}

SHARD_INDEX=0
SHARD_TOTAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  -j)
    shift
    [[ $# -gt 0 ]] || die "-j requires a positive integer"
    is_positive_int "$1" || die "-j requires a positive integer"
    MAX_PARALLEL="$1"
    shift
    ;;
  -j*)
    MAX_PARALLEL="${1#-j}"
    is_positive_int "$MAX_PARALLEL" || die "-j requires a positive integer"
    shift
    ;;
  --eval-only-pure)
    EVAL_ONLY_PURE=1
    shift
    ;;
  --shard)
    shift
    [[ $# -gt 0 ]] || die "--shard requires N/M"
    SHARD_SPEC="$1"
    parse_shard_spec "$SHARD_SPEC"
    shift
    ;;
  --shard=*)
    SHARD_SPEC="${1#--shard=}"
    parse_shard_spec "$SHARD_SPEC"
    shift
    ;;
  --summary-dir)
    shift
    [[ $# -gt 0 ]] || die "--summary-dir requires a directory"
    SUMMARY_DIR="$1"
    shift
    ;;
  --summary-dir=*)
    SUMMARY_DIR="${1#--summary-dir=}"
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  --)
    shift
    while [[ $# -gt 0 ]]; do
      CHECKS+=("$1")
      shift
    done
    ;;
  -*)
    die "unknown option: $1"
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
  CHECKS_TEXT=$(
    nix eval "${FLAKE_REF}#checks.${SYSTEM}" \
      --apply 'x: builtins.concatStringsSep "\n" (builtins.attrNames x)' \
      --raw \
      2>/dev/null
  )
  mapfile -t CHECKS < <(printf '%s\n' "$CHECKS_TEXT" | grep -v '^$')
fi

if [[ -n $SHARD_SPEC ]]; then
  SHARDED_CHECKS=()
  for i in "${!CHECKS[@]}"; do
    if (((i % SHARD_TOTAL) + 1 == SHARD_INDEX)); then
      SHARDED_CHECKS+=("${CHECKS[$i]}")
    fi
  done
  CHECKS=("${SHARDED_CHECKS[@]}")
fi

# Per-test logs are captured here. Kept on failure so a flake or real error
# can be diagnosed after the fact (the script no longer discards `nix build`
# output). Passing tests have their log file deleted to keep the dir tidy.
LOG_DIR="$(mktemp -d -t run-checks-XXXXXX)"
STATUS_FILE="$LOG_DIR/status.tsv"
echo "Per-test logs: ${LOG_DIR}"
echo ""

PASSED=0
FAILED=0
FAILED_NAMES=()
declare -A CHECK_STATUS
declare -A CHECK_LOG

TOTAL=${#CHECKS[@]}
echo "Running ${TOTAL} nix checks (parallelism: ${MAX_PARALLEL})..."
if [[ -n $SHARD_SPEC ]]; then
  echo "Shard: ${SHARD_SPEC}"
fi
if [[ $EVAL_ONLY_PURE -eq 1 ]]; then
  echo "Pure eval checks will force drvPath only."
fi
echo ""

run_check() {
  local check="$1"
  if [[ $EVAL_ONLY_PURE -eq 1 && -n ${PURE_EVAL_CHECKS[$check]+x} ]]; then
    nix eval "${FLAKE_REF}#checks.${SYSTEM}.${check}.drvPath" --raw
  else
    nix build "${FLAKE_REF}#checks.${SYSTEM}.${check}" --print-build-logs
  fi
}

if [[ $MAX_PARALLEL -le 1 ]]; then
  # Sequential mode — simple and clear
  for check in "${CHECKS[@]}"; do
    log="${LOG_DIR}/${check}.log"
    if run_check "$check" >"$log" 2>&1; then
      echo "  PASS  ${check}"
      CHECK_STATUS["$check"]="passed"
      CHECK_LOG["$check"]=""
      rm -f "$log"
      PASSED=$((PASSED + 1))
    else
      echo "  FAIL  ${check}  (log: ${log})"
      CHECK_STATUS["$check"]="failed"
      CHECK_LOG["$check"]="$log"
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
        CHECK_STATUS["$name"]="passed"
        CHECK_LOG["$name"]=""
        rm -f "$log"
        PASSED=$((PASSED + 1))
      else
        echo "  FAIL  ${name}  (log: ${log})"
        CHECK_STATUS["$name"]="failed"
        CHECK_LOG["$name"]="$log"
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
    run_check "$check" >"$log" 2>&1 &
    PID_TO_NAME[$!]="$check"
    PID_TO_LOG[$!]="$log"
    RUNNING=$((RUNNING + 1))
  done

  # Wait for remaining
  while [[ $RUNNING -gt 0 ]]; do
    reap_one
  done
fi

echo ""
echo "Results: ${PASSED} passed, ${FAILED} failed (${TOTAL} total)"

if [[ -n $SUMMARY_DIR ]]; then
  : >"$STATUS_FILE"
  for name in "${CHECKS[@]}"; do
    status="${CHECK_STATUS[$name]:-unknown}"
    log="${CHECK_LOG[$name]:-}"
    tail_file=""
    if [[ $status == "failed" && -n $log ]]; then
      tail_file="$LOG_DIR/${name}.tail"
      redacted_tail "$log" >"$tail_file"
    fi
    printf '%s\t%s\t%s\t%s\n' \
      "$name" "$status" "${tail_file:-"-"}" "./scripts/run-checks.sh $name" >>"$STATUS_FILE"
  done
  write_summary "$SUMMARY_DIR" "$STATUS_FILE"
  echo "Check summary: ${SUMMARY_DIR}/check-summary.json"
fi

# Tidy up an empty log dir on full success so we don't litter /tmp.
rmdir "$LOG_DIR" 2>/dev/null || true

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "Failed checks:"
  for name in "${FAILED_NAMES[@]}"; do
    echo "  - $name"
  done
  echo ""
  echo "Failure logs:"
  for name in "${FAILED_NAMES[@]}"; do
    log="${LOG_DIR}/${name}.log"
    echo ""
    echo "----- ${name} (${log}) -----"
    if [[ -s $log ]]; then
      cat "$log"
    else
      echo "(no log output captured)"
    fi
  done
  echo ""
  echo "Re-run a failing check with build logs:"
  echo "  nix build .#checks.${SYSTEM}.<name> --print-build-logs"
  exit 1
fi
