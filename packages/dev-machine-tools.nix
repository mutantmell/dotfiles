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
        git
        nix
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
  ];

  devMachineEntrypoint = pkgs.writeShellApplication {
    name = "dev-machine-entrypoint";
    runtimeInputs = with pkgs; [
      bashInteractive
      coreutils-full
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
