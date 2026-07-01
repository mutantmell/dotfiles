{
  pkgs,
  # claude-code is sourced from numtide/llm-agents.nix (daily-updated, prebuilt
  # in cache.numtide.com), passed in by flake.nix — nixpkgs lags multiple
  # releases. Defaults to nixpkgs so the package still evaluates standalone.
  claude-code,
  codex,
  imageName ? "dev-machine-dev",
  caCerts ? [],
}: let
  devMachineTools = import ../dev-machine-tools.nix {
    inherit pkgs claude-code codex;
  };
  inherit (devMachineTools) agentUid agentGid devTools teaConfigHome;
  extraCaCommands =
    pkgs.lib.concatMapStringsSep "\n" (cert: ''
      cat ${cert} >> etc/ssl/certs/ca-bundle.crt
      cat ${cert} >> etc/ssl/certs/ca-certificates.crt
    '')
    caCerts;
  # ── Phase 2.2 — custom dev image for the locked-down LLM dev machines ────────
  # (ai-dev-machine-kubevirt-plan.md). devpod's SSH provider builds/runs this as
  # a plain runc container *inside* the KubeVirt VM (the security boundary); the
  # devcontainer.json at the repo root pins it. This is where the actual dev
  # tooling lives. The VM base image also includes this closure because the
  # devcontainer bind-mounts the VM host /nix; that keeps /bin symlink targets
  # valid while builds execute through the host nix-daemon.
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
in
  pkgs.dockerTools.streamLayeredImage {
    name = imageName;
    tag = "latest";
    contents = devTools;

    # Register the nix db for all included store paths — without this the baked
    # `nix` treats its own closure as invalid and tries to rebuild/refetch it.
    includeNixDB = true;

    config = {
      Cmd = ["/bin/dev-machine-entrypoint"];
      User = "agent";
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
        "TEA_CONFIG_HOME=${teaConfigHome}"
      ];
    };

    # Client defaults only. The actual nix-daemon, sandbox policy, cgroups, and
    # uid-range support live on the KubeVirt VM host. The devcontainer bind-mounts
    # the host /nix so these client paths and the daemon's store view match.
    #
    # Keep passwd/group/nsswitch and the CA bundle as real image-root files rather
    # than Nix store symlinks: the runtime bind-mount over /nix would otherwise
    # make identity and TLS trust lookup depend on host-store paths matching the
    # dev image exactly.
    fakeRootCommands = ''
      mkdir -p etc/nix etc/ssl/certs tmp root home/agent nix
      chmod 1777 tmp
      chown ${agentUid}:${agentGid} home/agent
      cat > etc/passwd <<EOF
      root:x:0:0:root:/root:/bin/bash
      agent:x:${agentUid}:${agentGid}:agent:/home/agent:/bin/bash
      nobody:x:65534:65534:nobody:/var/empty:/bin/false
      EOF
      cat > etc/group <<EOF
      root:x:0:
      agent:x:${agentGid}:
      nobody:x:65534:
      EOF
      cat > etc/nsswitch.conf <<EOF
      passwd: files
      group: files
      hosts: files dns
      EOF
      cp -L --remove-destination ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-bundle.crt
      cp -L --remove-destination ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
      chmod u+w etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
      ${extraCaCommands}
      chmod 644 etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
      cat > etc/nix/nix.conf <<EOF
      experimental-features = nix-command flakes auto-allocate-uids cgroups
      build-users-group = nixbld
      allowed-users = root dev
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
