{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.runCommand "ci-summary-comment-post-test" {
  nativeBuildInputs = [pkgs.jq pkgs.python3];
} ''
  mkdir -p fake-bin
  cat > fake-bin/tea <<'SH'
  #!${pkgs.bash}/bin/bash
  set -euo pipefail

  echo "$*" >> "$TEA_CALLS"

  if [[ $1 != api ]]; then
    echo "unexpected tea command: $*" >&2
    exit 1
  fi
  shift

  method=GET
  data=
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        shift 2
        ;;
      --method)
        method=$2
        shift 2
        ;;
      --data)
        data=$2
        shift 2
        ;;
      *)
        endpoint=$1
        shift
        ;;
    esac
  done

  case "$method:$endpoint" in
    GET:/repos/\{owner\}/\{repo\}/pulls/5)
      printf '%s\n' "$TEA_PR_JSON"
      ;;
    GET:/user)
      printf '{"login":"ci-bot"}\n'
      ;;
    GET:/repos/\{owner\}/\{repo\}/issues/5/comments\?limit=100\&page=1)
      printf '%s\n' "$TEA_COMMENTS_PAGE_1"
      ;;
    GET:/repos/\{owner\}/\{repo\}/issues/5/comments\?limit=100\&page=2)
      printf '%s\n' "$TEA_COMMENTS_PAGE_2"
      ;;
    POST:/repos/\{owner\}/\{repo\}/issues/5/comments)
      jq -e '.body | contains("dotfiles-ci-summary:v1 sha=abc123")' "''${data#@}" > /dev/null
      jq . "''${data#@}" > "$TEA_WRITTEN_BODY"
      printf '{"id":9}\n'
      ;;
    PATCH:/repos/\{owner\}/\{repo\}/issues/comments/7)
      jq -e '.body | contains("dotfiles-ci-summary:v1 sha=abc123")' "''${data#@}" > /dev/null
      jq . "''${data#@}" > "$TEA_WRITTEN_BODY"
      printf '{"id":7}\n'
      ;;
    *)
      echo "unexpected api call: $method $endpoint" >&2
      exit 1
      ;;
  esac
  SH
  chmod +x fake-bin/tea

  cat > summary.json <<'JSON'
  {
    "schema": "dotfiles-ci-summary:v1",
    "head": "abc123",
    "status": "failed",
    "repository": "mutantmell/dotfiles",
    "pipeline_number": "42",
    "pipeline_url": "https://woodpecker.internal/repos/mutantmell/dotfiles/pipeline/42",
    "workflow": "full-checks",
    "step": "full-checks",
    "failed_checks": [
      {
        "name": "network-registry",
        "reproduce": "./scripts/run-checks.sh network-registry",
        "log_tail": "TOKEN=supersecret\nboom\n"
      }
    ]
  }
  JSON

  export PATH="$PWD/fake-bin:$PATH"
  export TEA_CALLS="$PWD/tea-calls.log"
  export TEA_WRITTEN_BODY="$PWD/written-body.json"
  export DOTFILES_CI_SUMMARY_RENDERER="${../../scripts/render-ci-summary-comment.py}"
  export DOTFILES_TEA_BIN="$PWD/fake-bin/tea"
  export TEA_PR_JSON='{"head":{"sha":"abc123"}}'
  export TEA_COMMENTS_PAGE_2='[]'

  export TEA_COMMENTS_PAGE_1='[]'
  python3 ${../../scripts/post-ci-summary-comment.py} 5 summary.json --repo mutantmell/dotfiles > create.out
  grep -F 'created dotfiles-ci-summary:v1 comment for PR #5 at abc123' create.out
  grep -F 'api --repo mutantmell/dotfiles --method POST --data @' tea-calls.log
  grep -F 'api --repo mutantmell/dotfiles /user' tea-calls.log
  jq -e '.body | contains("#### network\\-registry")' written-body.json > /dev/null
  ! jq -r .body written-body.json | grep -F supersecret

  : > tea-calls.log
  export TEA_PR_JSON='{"head":{"ref":"agent/topic","commit":{"sha":"abc123"}}}'
  export TEA_COMMENTS_PAGE_1='[{"id":7,"user":{"login":"ci-bot"},"body":"<!-- dotfiles-ci-summary:v1 sha=old -->\nstale"}]'
  export TEA_COMMENTS_PAGE_2='[]'
  python3 ${../../scripts/post-ci-summary-comment.py} 5 summary.json --repo mutantmell/dotfiles --author ci-bot > update.out
  grep -F 'updated dotfiles-ci-summary:v1 comment 7 for PR #5 at abc123' update.out
  grep -F 'api --repo mutantmell/dotfiles --method PATCH --data @' tea-calls.log

  : > tea-calls.log
  export TEA_PR_JSON='{"head":{"sha":"abc123"}}'
  export TEA_COMMENTS_PAGE_1='[{"id":7,"user":{"login":"someone-else"},"body":"<!-- dotfiles-ci-summary:v1 sha=abc123 -->\nhuman marker"}]'
  export TEA_COMMENTS_PAGE_2='[]'
  python3 ${../../scripts/post-ci-summary-comment.py} 5 summary.json --repo mutantmell/dotfiles --author ci-bot > ownership.out
  grep -F 'created dotfiles-ci-summary:v1 comment for PR #5 at abc123' ownership.out
  grep -F 'api --repo mutantmell/dotfiles --method POST --data @' tea-calls.log
  ! grep -F 'issues/comments/7' tea-calls.log

  : > tea-calls.log
  export TEA_PR_JSON='{"head":{"sha":"def456"}}'
  export TEA_COMMENTS_PAGE_1='[{"id":7,"user":{"login":"ci-bot"},"body":"<!-- dotfiles-ci-summary:v1 sha=old -->\nstale"}]'
  export TEA_COMMENTS_PAGE_2='[]'
  if python3 ${../../scripts/post-ci-summary-comment.py} 5 summary.json --repo mutantmell/dotfiles --author ci-bot > stale.out 2> stale.err; then
    echo "stale summary unexpectedly posted" >&2
    exit 1
  fi
  grep -F 'refusing stale CI comment' stale.err
  ! grep -E 'method (POST|PATCH)' tea-calls.log

  : > tea-calls.log
  export TEA_PR_JSON='{"head":{"ref":"agent/topic"}}'
  if python3 ${../../scripts/post-ci-summary-comment.py} 5 summary.json --repo mutantmell/dotfiles --author ci-bot > missing-head.out 2> missing-head.err; then
    echo "missing PR head unexpectedly posted" >&2
    exit 1
  fi
  grep -F 'could not determine current PR head' missing-head.err
  ! grep -E 'method (POST|PATCH)' tea-calls.log

  : > tea-calls.log
  export TEA_PR_JSON='{"head":{"sha":"def456"}}'
  export TEA_COMMENTS_PAGE_1='[{"id":7,"user":{"login":"ci-bot"},"body":"<!-- dotfiles-ci-summary:v1 sha=old -->\nstale"}]'
  python3 ${../../scripts/post-ci-summary-comment.py} 5 summary.json --repo mutantmell/dotfiles --author ci-bot --allow-stale > allow-stale.out
  grep -F 'updated dotfiles-ci-summary:v1 comment 7 for PR #5 at abc123' allow-stale.out

  : > tea-calls.log
  export TEA_PR_JSON='{"head":{"sha":"abc123"}}'
  export TEA_COMMENTS_PAGE_1="$(jq -n '[range(0;100) | {id: ., user: {login: "someone-else"}, body: "ordinary comment"}]')"
  export TEA_COMMENTS_PAGE_2='[{"id":7,"user":{"login":"ci-bot"},"body":"<!-- dotfiles-ci-summary:v1 sha=abc123 -->\ncurrent"}]'
  python3 ${../../scripts/post-ci-summary-comment.py} 5 summary.json --repo mutantmell/dotfiles --author ci-bot > pagination.out
  grep -F 'updated dotfiles-ci-summary:v1 comment 7 for PR #5 at abc123' pagination.out
  grep -F 'comments?limit=100&page=2' tea-calls.log
  ! grep -F -- '--method POST' tea-calls.log

  : > tea-calls.log
  python3 ${../../scripts/post-ci-summary-comment.py} 5 summary.json --dry-run > dry-run.md
  grep -F '<!-- dotfiles-ci-summary:v1 sha=abc123 -->' dry-run.md
  ! test -s tea-calls.log

  touch $out
''
