{
  pkgs,
  claude-code,
  codex,
}: let
  agentUid = "1000";
  agentGid = "1000";

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
      mkdir -p /home/agent /tmp
      chmod 1777 /tmp
      chown -R ${agentUid}:${agentGid} /home/agent 2>/dev/null || true

      if [[ $# -gt 0 ]]; then
        exec "$@"
      fi

      exec sleep infinity
    '';
  };

  # NSS files (passwd/group/nsswitch) with usable root and agent homes. OpenSSH
  # resolves `~` via getpwuid, so the passwd entries must match injected key
  # locations. /bin/sh comes from bashInteractive.
  nss = pkgs.symlinkJoin {
    name = "dev-machine-nss";
    paths = [
      (pkgs.writeTextDir "etc/passwd" ''
        root:x:0:0:root:/root:/bin/bash
        agent:x:${agentUid}:${agentGid}:agent:/home/agent:/bin/bash
        nobody:x:65534:65534:nobody:/var/empty:/bin/false
      '')
      (pkgs.writeTextDir "etc/group" ''
        root:x:0:
        agent:x:${agentGid}:
        nobody:x:65534:
      '')
      (pkgs.writeTextDir "etc/nsswitch.conf" ''
        passwd: files
        group: files
        hosts: files dns
      '')
    ];
  };

  devTools =
    [
      claude-code
      codex
      nss
      devMachineEntrypoint
    ]
    ++ agentWrappers
    ++ (with pkgs; [
      nix
      git
      ripgrep
      jq
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
      less
      openssh
      busybox
      dockerTools.usrBinEnv
    ]);
in {
  inherit agentUid agentGid agentWrappers devMachineEntrypoint nss devTools;
}
