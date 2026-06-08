{
  pkgs,
  # claude-code is sourced from numtide/llm-agents.nix (daily-updated, prebuilt
  # in cache.numtide.com), passed in by flake.nix — nixpkgs lags multiple
  # releases. Defaults to nixpkgs so the package still evaluates standalone.
  claude-code ? pkgs.claude-code,
  codex ? pkgs.codex-acp,
}: let
  inherit (pkgs) lib;

  # NSS files (passwd/group/nsswitch) — like dockerTools.fakeNss BUT with root's
  # home as /root. fakeNss hardcodes /var/empty, which breaks OpenSSH: ssh resolves
  # `~` via getpwuid (NOT $HOME), so it looks for ~/.ssh/{config,key} under
  # /var/empty and never finds the injected cc key in /root/.ssh. A root passwd
  # entry is also required for docker/runc to run the container as root, and
  # nix/git/ssh need user + host resolution. /bin/sh comes from bashInteractive.
  nss = pkgs.symlinkJoin {
    name = "dev-machine-nss";
    paths = [
      (pkgs.writeTextDir "etc/passwd" ''
        root:x:0:0:root:/root:/bin/bash
        nobody:x:65534:65534:nobody:/var/empty:/bin/false
      '')
      (pkgs.writeTextDir "etc/group" ''
        root:x:0:
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
  # (sshd + docker + a service user) and carries none of this.
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
      # /etc/passwd (root home /root) + /etc/group + /etc/nsswitch.conf — see `nss`.
      nss
    ]
    ++ (with pkgs; [
      # Nix itself (flakes enabled via nix.conf below) + the repo's formatters
      # and search tooling. nixpkgs over npm ([[feedback_nixpkgs_over_npm]]).
      nix
      git
      ripgrep
      jq
      alejandra
      treefmt

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
      Cmd = ["/bin/bash"];
      WorkingDir = "/workspaces";
      Env = [
        "PATH=/bin"
        "USER=root"
        "HOME=/root"
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

    # nix.conf + a couple of dirs nix builds expect. The container runs as its
    # own root (devpod's runc container under the VM's docker), and the VM is the
    # security boundary (decision 4), so nix builds single-user as root with no
    # nixbld group.
    #
    # sandbox = true: the container gets CAP_SYS_ADMIN via the devcontainer.json
    #   `runArgs` (`--cap-add=SYS_ADMIN`), which lifts docker's default-seccomp
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
    fakeRootCommands = ''
      mkdir -p etc/nix tmp root/workspaces
      chmod 1777 tmp
      cat > etc/nix/nix.conf <<EOF
      experimental-features = nix-command flakes
      build-users-group =
      sandbox = true
      extra-sandbox-paths = /dev/kvm
      EOF
    '';
  }
