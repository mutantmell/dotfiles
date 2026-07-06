{
  pkgs,
  claude-code,
  codex,
}: let
  agentUid = "1000";
  agentGid = "1000";
  teaConfigHome = "/home/agent/.config/tea";

  mkAgentWrapper = name: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        bashInteractive
        coreutils-full
        curl
        git
        jq
        nix
        tea
      ];
      text = ''
        find_repo_root() {
          if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
            printf '%s\n' "$git_root"
            return 0
          fi

          if [[ -d /workspaces/dotfiles/.git ]]; then
            printf '%s\n' /workspaces/dotfiles
            return 0
          fi

          printf 'agent wrapper: run from inside the dotfiles checkout or mount it at /workspaces/dotfiles\n' >&2
          return 1
        }

        repo_root=$(find_repo_root)
        cd "$repo_root"

        ${text}
      '';
    };

  agentWrappers = [
    (mkAgentWrapper "agent-fmt" ''
      exec nix fmt "$@"
    '')
    (mkAgentWrapper "agent-preflight" ''
      exec ./scripts/agent-preflight.sh "$@"
    '')
    (mkAgentWrapper "agent-preflight-quick" ''
      exec ./scripts/agent-preflight.sh --quick "$@"
    '')
    (mkAgentWrapper "agent-preflight-full" ''
      exec ./scripts/agent-preflight.sh --full "$@"
    '')
    (mkAgentWrapper "agent-checks" ''
      exec ./scripts/run-checks.sh "$@"
    '')
    (mkAgentWrapper "agent-build-check" ''
      if [[ $# -lt 1 ]]; then
        printf 'usage: agent-build-check <check-name> [nix-build-arg ...]\n' >&2
        exit 2
      fi

      check_name=$1
      shift
      exec nix build ".#checks.x86_64-linux.$check_name" "$@"
    '')
    (mkAgentWrapper "agent-smoke" ''
      exec ./scripts/dev-machine-smoke.sh "$@"
    '')
    (mkAgentWrapper "agent-pr-create" ''
            require_tea_login() {
              if ! tea whoami >/dev/null 2>&1; then
                printf 'agent-pr-create: tea is not configured for Forgejo in this dev-machine\n' >&2
                printf 'rerun dev-machine up after configuring programs.dev-machine.forgejoTokenFile.\n' >&2
                exit 1
              fi
            }

            usage() {
              cat >&2 <<'USAGE'
      usage: agent-pr-create --title TITLE [--body-file FILE|--body TEXT] [--base BRANCH] [--head OWNER:BRANCH] [--repo OWNER/REPO]

      Creates a Forgejo PR using a Markdown body from --body-file, --body, or stdin.
      Defaults to --repo mutantmell/dotfiles, --base main, and --head cc:<current-branch>.
      USAGE
            }

            repo=mutantmell/dotfiles
            base=main
            head=
            title=
            body=
            body_file=

            while [[ $# -gt 0 ]]; do
              case "$1" in
              --repo)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                repo=$1
                shift
                ;;
              --repo=*)
                repo=''${1#--repo=}
                shift
                ;;
              --base)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                base=$1
                shift
                ;;
              --base=*)
                base=''${1#--base=}
                shift
                ;;
              --head)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                head=$1
                shift
                ;;
              --head=*)
                head=''${1#--head=}
                shift
                ;;
              --title|-t)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                title=$1
                shift
                ;;
              --title=*)
                title=''${1#--title=}
                shift
                ;;
              --body|-d)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                body=$1
                shift
                ;;
              --body=*)
                body=''${1#--body=}
                shift
                ;;
              --body-file|-F)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                body_file=$1
                shift
                ;;
              --body-file=*)
                body_file=''${1#--body-file=}
                shift
                ;;
              -h|--help)
                usage
                exit 0
                ;;
              *)
                printf 'agent-pr-create: unknown argument: %s\n' "$1" >&2
                usage
                exit 2
                ;;
              esac
            done

            require_tea_login

            if [[ -z $title ]]; then
              printf 'agent-pr-create: --title is required\n' >&2
              usage
              exit 2
            fi

            if [[ -n $body_file ]]; then
              body=$(cat "$body_file")
            elif [[ -z $body && ! -t 0 ]]; then
              body=$(cat)
            fi

            if [[ -z $head ]]; then
              branch=$(git branch --show-current 2>/dev/null || true)
              if [[ -z $branch ]]; then
                printf 'agent-pr-create: not on a named branch; pass --head OWNER:BRANCH\n' >&2
                exit 2
              fi
              head="cc:$branch"
            fi

            exec tea pr create --repo "$repo" --head "$head" --base "$base" --title "$title" --description "$body"
    '')
    (mkAgentWrapper "agent-pr-status" ''
      require_tea_login() {
        if ! tea whoami >/dev/null 2>&1; then
          printf 'agent-pr-status: tea is not configured for Forgejo in this dev-machine\n' >&2
          printf 'rerun dev-machine up after configuring programs.dev-machine.forgejoTokenFile.\n' >&2
          exit 1
        fi
      }

      usage() {
        printf 'usage: agent-pr-status [pr-number]\n' >&2
      }

      require_tea_login
      if [[ $# -gt 1 ]]; then
        usage
        exit 2
      fi

      fields=index,title,state,head,base,mergeable,ci,updated,url

      if [[ $# -eq 1 ]]; then
        pr_id=$1
        pr=$(tea pr "$pr_id" --fields "$fields" --output json)
      else
        prs=$(tea pr list --state all --limit 100 --fields "$fields" --output json)
        branch=$(git branch --show-current 2>/dev/null || true)
        if [[ -z $branch ]]; then
          printf 'agent-pr-status: not on a named branch; pass a PR number\n' >&2
          jq -r '.[] | "#\(.index) [\(.state)] \(.title) head=\(.head | tostring) ci=\(.ci | tostring)"' <<<"$prs"
          exit 1
        fi

        pr_id=$(
          jq -r --arg branch "$branch" '
            def head_text:
              .head
              | if type == "object" then (.ref // .name // .label // .branch // "")
                elif type == "string" then .
                else ""
                end;
            [
              .[]
              | select(.state == "open")
              | select((head_text == $branch) or (head_text | endswith("/" + $branch)) or (head_text | endswith(":" + $branch)))
            ][0].index // empty
          ' <<<"$prs"
        )

        if [[ -z $pr_id ]]; then
          printf 'agent-pr-status: no open PR found for branch %s; pass a PR number\n' "$branch" >&2
          jq -r '.[] | "#\(.index) [\(.state)] \(.title) head=\(.head | tostring) ci=\(.ci | tostring)"' <<<"$prs"
          exit 1
        fi

        pr=$(
          jq -c --arg pr_id "$pr_id" '
            map(select((.index | tostring) == $pr_id))[0] // empty
          ' <<<"$prs"
        )
      fi

      if [[ -z $pr ]]; then
        printf 'agent-pr-status: PR #%s was not found by tea\n' "$pr_id" >&2
        exit 1
      fi

      jq -r '
        def head_text:
          .head
          | if type == "object" then (.ref // .name // .label // .branch // "")
            elif type == "string" then .
            else ""
            end;
        "PR #\(.index): \(.title)\nstate: \(.state)\nhead: \(head_text)\nbase: \(.base | tostring)\nmergeable: \(.mergeable | tostring)\nci: \(.ci | tostring)\nurl: \(.url // "")"
      ' <<<"$pr"

    '')
    (mkAgentWrapper "agent-ci-status" ''
            usage() {
              cat >&2 <<'USAGE'
      usage: agent-ci-status [--pipeline N|--pr N|--commit SHA]

      Shows Woodpecker pipeline and step state. With no selector, uses HEAD.
      USAGE
            }

            require_woodpecker_api() {
              if [[ -z ''${WOODPECKER_SERVER:-} || -z ''${WOODPECKER_TOKEN:-} ]]; then
                printf 'agent-ci-status: WOODPECKER_SERVER and WOODPECKER_TOKEN must be set\n' >&2
                exit 1
              fi
            }

            woodpecker_get() {
              curl -fsS -H "Authorization: Bearer $WOODPECKER_TOKEN" "$WOODPECKER_SERVER$1"
            }

            pipeline_number=
            pr_id=
            commit_sha=
            repo_id=''${DOTFILES_WOODPECKER_REPO_ID:-1}

            while [[ $# -gt 0 ]]; do
              case "$1" in
              --pipeline)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                pipeline_number=$1
                shift
                ;;
              --pipeline=*)
                pipeline_number=''${1#--pipeline=}
                shift
                ;;
              --pr)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                pr_id=$1
                shift
                ;;
              --pr=*)
                pr_id=''${1#--pr=}
                shift
                ;;
              --commit)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                commit_sha=$1
                shift
                ;;
              --commit=*)
                commit_sha=''${1#--commit=}
                shift
                ;;
              -h|--help)
                usage
                exit 0
                ;;
              *)
                if [[ $1 =~ ^[0-9]+$ && -z $pr_id && -z $pipeline_number && -z $commit_sha ]]; then
                  pr_id=$1
                  shift
                else
                  printf 'agent-ci-status: unknown argument: %s\n' "$1" >&2
                  usage
                  exit 2
                fi
                ;;
              esac
            done

            require_woodpecker_api

            if [[ -n $pr_id && -z $commit_sha ]]; then
              commit_sha=$(tea pr --repo mutantmell/dotfiles "$pr_id" --fields headSha --output json | jq -r '.headSha')
            fi
            if [[ -z $pipeline_number ]]; then
              if [[ -z $commit_sha ]]; then
                commit_sha=$(git rev-parse HEAD)
              fi
              pipeline_number=$(
                woodpecker_get "/api/repos/$repo_id/pipelines?perPage=50" |
                  jq -r --arg commit "$commit_sha" '[.[] | select(.commit == $commit)][0].number // empty'
              )
              if [[ -z $pipeline_number ]]; then
                printf 'agent-ci-status: no Woodpecker pipeline found for commit %s\n' "$commit_sha" >&2
                exit 1
              fi
            fi

            woodpecker_get "/api/repos/$repo_id/pipelines/$pipeline_number" |
              jq -r '
                "pipeline #\(.number): \(.status)",
                "event: \(.event) ref: \(.ref) commit: \(.commit[0:12])",
                "url: \(.forge_url)",
                (
                  .workflows[]
                  | "workflow \(.name): \(.state)\(if .error then " (" + .error + ")" else "" end)",
                    (.children[] | "  step #\(.id) \(.name): \(.state) exit=\(.exit_code // "n/a")")
                )
              '
    '')
    (mkAgentWrapper "agent-ci-logs" ''
            usage() {
              cat >&2 <<'USAGE'
      usage: agent-ci-logs [--pipeline N|--pr N|--commit SHA] [--step NAME_OR_ID] [--tail N]

      Prints decoded Woodpecker logs. Defaults to the full-checks step for HEAD.
      USAGE
            }

            require_woodpecker_api() {
              if [[ -z ''${WOODPECKER_SERVER:-} || -z ''${WOODPECKER_TOKEN:-} ]]; then
                printf 'agent-ci-logs: WOODPECKER_SERVER and WOODPECKER_TOKEN must be set\n' >&2
                exit 1
              fi
            }

            woodpecker_get() {
              curl -fsS -H "Authorization: Bearer $WOODPECKER_TOKEN" "$WOODPECKER_SERVER$1"
            }

            pipeline_number=
            pr_id=
            commit_sha=
            step_selector=full-checks
            tail_lines=
            repo_id=''${DOTFILES_WOODPECKER_REPO_ID:-1}

            while [[ $# -gt 0 ]]; do
              case "$1" in
              --pipeline)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                pipeline_number=$1
                shift
                ;;
              --pipeline=*)
                pipeline_number=''${1#--pipeline=}
                shift
                ;;
              --pr)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                pr_id=$1
                shift
                ;;
              --pr=*)
                pr_id=''${1#--pr=}
                shift
                ;;
              --commit)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                commit_sha=$1
                shift
                ;;
              --commit=*)
                commit_sha=''${1#--commit=}
                shift
                ;;
              --step)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                step_selector=$1
                shift
                ;;
              --step=*)
                step_selector=''${1#--step=}
                shift
                ;;
              --tail)
                shift
                [[ $# -gt 0 ]] || { usage; exit 2; }
                tail_lines=$1
                shift
                ;;
              --tail=*)
                tail_lines=''${1#--tail=}
                shift
                ;;
              -h|--help)
                usage
                exit 0
                ;;
              *)
                if [[ $1 =~ ^[0-9]+$ && -z $pr_id && -z $pipeline_number && -z $commit_sha ]]; then
                  pr_id=$1
                  shift
                else
                  printf 'agent-ci-logs: unknown argument: %s\n' "$1" >&2
                  usage
                  exit 2
                fi
                ;;
              esac
            done

            require_woodpecker_api

            if [[ -n $pr_id && -z $commit_sha ]]; then
              commit_sha=$(tea pr --repo mutantmell/dotfiles "$pr_id" --fields headSha --output json | jq -r '.headSha')
            fi
            if [[ -z $pipeline_number ]]; then
              if [[ -z $commit_sha ]]; then
                commit_sha=$(git rev-parse HEAD)
              fi
              pipeline_number=$(
                woodpecker_get "/api/repos/$repo_id/pipelines?perPage=50" |
                  jq -r --arg commit "$commit_sha" '[.[] | select(.commit == $commit)][0].number // empty'
              )
              if [[ -z $pipeline_number ]]; then
                printf 'agent-ci-logs: no Woodpecker pipeline found for commit %s\n' "$commit_sha" >&2
                exit 1
              fi
            fi

            pipeline_json=$(woodpecker_get "/api/repos/$repo_id/pipelines/$pipeline_number")
            if [[ $step_selector =~ ^[0-9]+$ ]]; then
              step_id=$step_selector
            else
              step_id=$(
                jq -r --arg step "$step_selector" '
                  [.workflows[]?.children[]? | select(.name == $step)][0].id // empty
                ' <<<"$pipeline_json"
              )
            fi
            if [[ -z ''${step_id:-} ]]; then
              printf 'agent-ci-logs: no step %s found in pipeline %s\n' "$step_selector" "$pipeline_number" >&2
              jq -r '.workflows[]?.children[]? | "  #\(.id) \(.name): \(.state)"' <<<"$pipeline_json" >&2
              exit 1
            fi

            logs=$(
              woodpecker_get "/api/repos/$repo_id/logs/$pipeline_number/$step_id" |
                jq -r '.[]? | .data // empty' |
                while IFS= read -r line; do
                  printf '%s' "$line" | base64 -d
                  printf '\n'
                done
            )

            if [[ -n $tail_lines ]]; then
              printf '%s\n' "$logs" | tail -n "$tail_lines"
            else
              printf '%s\n' "$logs"
            fi
    '')
    (mkAgentWrapper "agent-pr-comments" ''
      require_tea_login() {
        if ! tea whoami >/dev/null 2>&1; then
          printf 'agent-pr-comments: tea is not configured for Forgejo in this dev-machine\n' >&2
          exit 1
        fi
      }

      if [[ $# -ne 1 ]]; then
        printf 'usage: agent-pr-comments <pr-number>\n' >&2
        exit 2
      fi

      require_tea_login
      pr_id=$1
      lifecycle=$(tea pr "$pr_id" --comments --limit 100 --output json)
      review=$(tea pr review-comments "$pr_id" --output json)
      jq -n \
        --argjson lifecycle "$lifecycle" \
        --argjson review_comments "$review" \
        '{lifecycle: $lifecycle, review_comments: $review_comments}'
    '')
    (mkAgentWrapper "agent-pr-comment" ''
      require_tea_login() {
        if ! tea whoami >/dev/null 2>&1; then
          printf 'agent-pr-comment: tea is not configured for Forgejo in this dev-machine\n' >&2
          exit 1
        fi
      }

      if [[ $# -lt 2 ]]; then
        printf 'usage: agent-pr-comment <pr-number> <message>\n' >&2
        exit 2
      fi

      require_tea_login
      pr_id=$1
      shift
      exec tea comment "$pr_id" "$*"
    '')
  ];

  devMachineEntrypoint = pkgs.writeShellApplication {
    name = "dev-machine-entrypoint";
    runtimeInputs = with pkgs; [
      bashInteractive
      coreutils-full
      gnugrep
    ];
    text = ''
            if [[ $(id -u) -eq 0 ]]; then
              mkdir -p /home/agent /tmp
              chmod 1777 /tmp
              chown -R ${agentUid}:${agentGid} /home/agent 2>/dev/null || true
              mkdir -p ${teaConfigHome}
              chmod 700 ${teaConfigHome}
              chown -R ${agentUid}:${agentGid} ${teaConfigHome} 2>/dev/null || true
            else
              [[ -d /home/agent ]] || {
                echo "dev-machine-entrypoint: /home/agent is missing" >&2
                exit 1
              }
              [[ -d /tmp ]] || {
                echo "dev-machine-entrypoint: /tmp is missing" >&2
                exit 1
              }
              mkdir -p ${teaConfigHome}
              chmod 700 ${teaConfigHome}
            fi

            mkdir -p /home/agent/.config/direnv
            touch /home/agent/.bashrc /home/agent/.config/direnv/direnvrc
            if ! grep -qF 'source /share/nix-direnv/direnvrc' /home/agent/.config/direnv/direnvrc; then
              printf '%s\n' 'source /share/nix-direnv/direnvrc' >> /home/agent/.config/direnv/direnvrc
            fi
            if ! grep -qF '# dev-machine direnv setup' /home/agent/.bashrc; then
              cat >> /home/agent/.bashrc <<'EOF'

      # dev-machine direnv setup
      if command -v direnv >/dev/null 2>&1; then
        eval "$(direnv hook bash)"
      fi
      EOF
            fi
            chown -R ${agentUid}:${agentGid} /home/agent/.bashrc /home/agent/.config/direnv 2>/dev/null || true

            if [[ $# -gt 0 ]]; then
              exec "$@"
            fi

            exec sleep infinity
    '';
  };

  devTools =
    [
      claude-code
      codex
      devMachineEntrypoint
    ]
    ++ agentWrappers
    ++ (with pkgs; [
      nix
      git
      ripgrep
      fd
      jq
      curl
      wget
      python3
      just
      direnv
      nix-direnv
      alejandra
      treefmt
      zellij
      bashInteractive
      coreutils-full
      cacert
      gnutar
      gzip
      xz
      findutils
      gnugrep
      gnused
      gawk
      diffutils
      patch
      file
      which
      util-linux
      procps
      iproute2
      dnsutils
      netcat-openbsd
      rsync
      unzip
      zstd
      gnumake
      pkg-config
      less
      openssh
      tea
      busybox
      dockerTools.usrBinEnv
    ]);
in {
  inherit agentUid agentGid agentWrappers devMachineEntrypoint devTools teaConfigHome;
}
