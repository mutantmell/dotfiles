{
  pkgs,
  # claude-code is sourced from numtide/llm-agents.nix (daily-updated, prebuilt
  # in cache.numtide.com), passed in by flake.nix — nixpkgs lags multiple
  # releases. Defaults to nixpkgs so the package still evaluates standalone.
  claude-code,
  codex,
}: let
  inherit (pkgs) lib;

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

  nixDaemonEntrypoint = pkgs.writeShellApplication {
    name = "dev-machine-entrypoint";
    runtimeInputs = with pkgs; [
      bashInteractive
      coreutils-full
      nix
    ];
    text = ''
      mkdir -p \
        /nix/var/nix/daemon-socket \
        /nix/var/nix/profiles/per-user/root \
        /nix/var/nix/profiles/per-user/agent \
        /home/agent \
        /tmp
      chmod 1777 /tmp
      chown -R ${agentUid}:${agentGid} /home/agent /nix/var/nix/profiles/per-user/agent 2>/dev/null || true

      if [[ ! -S /nix/var/nix/daemon-socket/socket ]]; then
        env -u NIX_REMOTE nix daemon --log-format raw >/tmp/nix-daemon.log 2>&1 &
        daemon_pid=$!
        for _ in {1..100}; do
          if [[ -S /nix/var/nix/daemon-socket/socket ]]; then
            break
          fi
          if ! kill -0 "$daemon_pid" 2>/dev/null; then
            echo "dev-machine-entrypoint: nix daemon exited before creating its socket" >&2
            cat /tmp/nix-daemon.log >&2 || true
            wait "$daemon_pid"
            exit 1
          fi
          sleep 0.1
        done
        if [[ ! -S /nix/var/nix/daemon-socket/socket ]]; then
          echo "dev-machine-entrypoint: nix-daemon did not create its socket" >&2
          cat /tmp/nix-daemon.log >&2 || true
          wait "$daemon_pid"
          exit 1
        fi
      fi

      if [[ $# -gt 0 ]]; then
        exec "$@"
      fi

      exec sleep infinity
    '';
  };

  # NSS files (passwd/group/nsswitch) — like dockerTools.fakeNss BUT with usable
  # root and agent homes. OpenSSH resolves `~` via getpwuid (NOT $HOME), so the
  # passwd entries must match the injected key locations. A root passwd entry is
  # still required for runc and for the daemon bootstrap; agents attach as uid
  # 1000. /bin/sh comes from bashInteractive.
  nss = pkgs.symlinkJoin {
    name = "dev-machine-nss";
    paths = [
      (pkgs.writeTextDir "etc/passwd" ''
        root:x:0:0:root:/root:/bin/bash
        agent:x:${agentUid}:${agentGid}:agent:/home/agent:/bin/bash
        nixbld1:x:30001:30000:nix build user 1:/var/empty:/bin/false
        nixbld2:x:30002:30000:nix build user 2:/var/empty:/bin/false
        nixbld3:x:30003:30000:nix build user 3:/var/empty:/bin/false
        nixbld4:x:30004:30000:nix build user 4:/var/empty:/bin/false
        nixbld5:x:30005:30000:nix build user 5:/var/empty:/bin/false
        nixbld6:x:30006:30000:nix build user 6:/var/empty:/bin/false
        nixbld7:x:30007:30000:nix build user 7:/var/empty:/bin/false
        nixbld8:x:30008:30000:nix build user 8:/var/empty:/bin/false
        nixbld9:x:30009:30000:nix build user 9:/var/empty:/bin/false
        nixbld10:x:30010:30000:nix build user 10:/var/empty:/bin/false
        nobody:x:65534:65534:nobody:/var/empty:/bin/false
      '')
      (pkgs.writeTextDir "etc/group" ''
        root:x:0:
        agent:x:${agentGid}:
        nixbld:x:30000:nixbld1,nixbld2,nixbld3,nixbld4,nixbld5,nixbld6,nixbld7,nixbld8,nixbld9,nixbld10
        nobody:x:65534:
      '')
      (pkgs.writeTextDir "etc/nsswitch.conf" ''
        passwd: files
        group: files
        hosts: files dns
      '')
    ];
  };

  # ── Phase 2.2 — custom dev image for the locked-down LLM dev machines ────────
  # (ai-dev-machine-kubevirt-plan.md). devpod's SSH provider builds/runs this as
  # a plain runc container *inside* the KubeVirt VM (the security boundary); the
  # devcontainer.json at the repo root pins it. This is where the actual dev
  # tooling lives — the VM base image (packages/dev-machine-image) stays thin
  # (sshd + Podman + a service user) and carries none of this.
  #
  # Built with Nix (streamLayeredImage), not a Dockerfile, so the contents are
  # pinned to this flake's nixpkgs and there is no apt/npm build step — the
  # heavyweight-default-image complaint the plan calls out. `includeNixDB = true`
  # registers every store path in the image's nix db, so the baked `nix` can
  # `nix build`/`nix develop` against this flake without re-fetching its own
  # closure.
  #
  # Publish (operator/CI step, NOT done here — keeps the build pure, no daemon):
  #   nix build .#dev-machine-dev-image
  #   ./result | gzip --fast | skopeo copy \
  #     docker-archive:/dev/stdin \
  #     docker://forgejo.internal/mutantmell/dev-machine-dev:latest
  #   # (or `skopeo copy docker-archive:<(./result) docker://…` without gzip)
  #
  # FRESHNESS — keep claude current via REPUBLISH CADENCE, not runtime updates.
  # These dev machines are ephemeral per session but the published `:latest` tag
  # outlives any one claude-code release. The fix is a CI job that bumps the
  # llm-agents.nix input (`nix flake update llm-agents`), rebuilds, and re-pushes
  # `:latest` — cheap to run daily because numtide ships the build prebuilt in
  # cache.numtide.com, so each new `dev-machine up` pulls a <~24h-old claude with
  # ZERO sandbox egress. That CI job is documented-intent, not built yet (CI is
  # itself deferred). Until it lands, the Phase 3 `dev-machine up` wrapper can
  # carry the cadence instead — e.g. build + push this image on create by
  # default (a cache-pull of the prebuilt claude, so cheap), so every session
  # starts current without waiting on CI. Runtime self-update is deliberately
  # NOT the mechanism:
  # it would need egress the Phase 5 lockdown forbids, fights the read-only nix
  # store, and would mutate the toolchain mid-session (losing image-digest ↔
  # claude-version auditability). The lockdown-respecting runtime path — mirror
  # claude into creil and pull at session start — is the escalation reserved for
  # the *persistent* workstation track (incus-workstation-migration-plan.md),
  # not these ephemeral sessions.
  #
  # Build-host / CI nix.conf needs numtide's cache to get the prebuilt claude:
  #   extra-substituters = https://cache.numtide.com
  #   extra-trusted-public-keys = niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=
  # (This is build-host only — NOT baked into the image and NOT a sandbox egress
  # allowance; the agent is already in the image by the time it runs.)

  # Tooling baked into the image: enough for an agent to have a working shell and
  # drive this flake immediately. The flake-specific heavy deps come from
  # `nix develop`/`nix build` at runtime (Attic-cached via zeiss once that cache
  # exists — deferred for now, so the first build is uncached).
  #
  # kubectl is deliberately ABSENT (Phase 3 lockdown): cluster/orchestration
  # tooling stays on the operator's workstation, off the sandbox PATH, so an
  # agent in here can't see or reach the cluster. Network lockdown (Phase 5)
  # blocks the API regardless, but we don't ship the tool either.
  devTools =
    [
      # Coding agents — from numtide (param), not nixpkgs. See header.
      claude-code
      codex
      # /etc/passwd + /etc/group + /etc/nsswitch.conf — see `nss`.
      nss
      nixDaemonEntrypoint
    ]
    ++ agentWrappers
    ++ (with pkgs; [
      # Nix itself (flakes enabled via nix.conf below) + the repo's formatters
      # and search tooling. nixpkgs over npm ([[feedback_nixpkgs_over_npm]]).
      nix
      git
      ripgrep
      jq
      alejandra
      treefmt

      # Phase 6 (remote/mobile operator access): the durable in-container session
      # multiplexer. The agent runs inside a zellij session named `main`; a mobile
      # operator tssh's into the VM and `dev-attach`es into that same session, so
      # work survives a dropped connection. Lives in the dev image because the
      # session must run where the agent runs — inside the devcontainer.
      zellij

      # A usable base userland for an interactive shell + git/nix over HTTPS/SSH.
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
      # DevPod wraps its in-container SSH helper with `su -c ... agent` whenever
      # callers pass `devpod ssh --user agent`. Use BusyBox's non-PAM su applet;
      # the shadow/PAM su output fails in this minimal Docker image.
      busybox

      # /usr/bin/env for `#!/usr/bin/env` shebangs (./scripts/*, run-checks.sh, much
      # tooling); /bin/sh already comes from bashInteractive. (passwd/group/nsswitch
      # come from `nss` above, NOT dockerTools.fakeNss — its /var/empty root home
      # breaks OpenSSH key lookup.)
      dockerTools.usrBinEnv
    ]);
in
  pkgs.dockerTools.streamLayeredImage {
    name = "dev-machine-dev";
    tag = "latest";
    contents = devTools;

    # Register the nix db for all included store paths — without this the baked
    # `nix` treats its own closure as invalid and tries to rebuild/refetch it.
    includeNixDB = true;

    config = {
      Cmd = ["/bin/dev-machine-entrypoint"];
      WorkingDir = "/workspaces";
      Env = [
        "PATH=/bin"
        "USER=agent"
        "HOME=/home/agent"
        "NIX_REMOTE=daemon"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
        # `nix flake`/legacy nix-channel fallback; flakes are the real interface.
        "NIX_PATH=nixpkgs=flake:nixpkgs"
        # Disable claude's self-updater: the version is managed by the image
        # publish cadence (see header), the nix store is read-only so it can't
        # write anyway, and updating would attempt egress the Phase 5 lockdown
        # forbids. Belt-and-suspenders even if the package already sets it.
        "DISABLE_AUTOUPDATER=1"
      ];
    };

    # nix.conf + a couple of dirs nix builds expect. The container still starts
    # one root-owned bootstrap process because nix-daemon needs to own the store
    # socket, but DevPod attaches the agent as uid 1000 and Nix clients use
    # NIX_REMOTE=daemon instead of single-user root writes.
    #
    # sandbox = true: the container gets CAP_SYS_ADMIN via the devcontainer.json
    #   `runArgs` (`--cap-add=SYS_ADMIN`), which lifts the default container seccomp
    #   block on the namespace/mount syscalls Nix's sandbox needs. (An earlier
    #   note here claimed in-container sandboxing was impossible — that test was
    #   run WITHOUT the cap; the VM kernel does support userns,
    #   max_user_namespaces is non-zero.) Sandboxing matters beyond purity: it is
    #   what keeps /homeless-shelter (the build's fake $HOME) inside each build's
    #   private mount namespace instead of leaking onto the real container fs and
    #   wedging later builds when one is killed mid-flight.
    # extra-sandbox-paths = /dev/kvm: the sandbox otherwise exposes only a minimal
    #   /dev, which would hide /dev/kvm from the nixosTest suite's nested QEMU —
    #   the whole reason /dev/kvm is surfaced into the container. This keeps it
    #   reachable from inside the build sandbox. (system-features already
    #   auto-detects `kvm`/`nixos-test` from the device node.)
    # auto-allocate-uids + uid-range: required for nixosTest container machines.
    #   Keep agent untrusted; these are daemon policy, not per-command options the
    #   agent may relax. Nix also gets use-cgroups=true so the daemon establishes
    #   its root cgroup at startup instead of first discovering cgroups inside an
    #   individual uid-range build.
    fakeRootCommands = ''
      mkdir -p etc/nix tmp root home/agent
      chmod 1777 tmp
      chown ${agentUid}:${agentGid} home/agent
      cat > etc/nix/nix.conf <<EOF
      experimental-features = nix-command flakes auto-allocate-uids cgroups
      build-users-group = nixbld
      allowed-users = root agent
      trusted-users = root
      sandbox = true
      sandbox-fallback = false
      auto-allocate-uids = true
      use-cgroups = true
      extra-system-features = nixos-test kvm uid-range
      extra-sandbox-paths = /dev/kvm
      EOF
    '';
  }
