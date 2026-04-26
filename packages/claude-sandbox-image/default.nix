# OCI image for sandboxed Claude Code environments.
#
# Provides a minimal environment with shell, git, nodejs, and common CLI tools.
# Runs sshd on port 22 with authorized keys from the project key registry.
# Designed to run on the deployd vDMZ network with its own IP.
#
# Expected environment variables (injected by cc-sandbox via deployd env):
#   SANDBOX_REPO_URL — git clone URL for the workspace repo
#   SANDBOX_DNS      — space-separated DNS server IPs (written to /etc/resolv.conf)
{
  pkgs,
  lib ? pkgs.lib,
}: let
  user = "claude";
  uid = "1000";
  gid = "1000";

  inherit (pkgs.mmell.lib.data) keys;
  authorizedKeys = builtins.concatStringsSep "\n" [
    keys.ssh.deploy
    keys.ssh.home
    keys.ssh.edith
  ];

  # Internal step-ca root certificate for TLS to creil.internal, etc.
  internalCaCert = pkgs.mmell.lib.data.pki.root;

  # Minimal passwd/group for the non-root user.
  # Home is /workspace so SSH sessions land there directly.
  passwdFile = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/bash
    sshd:x:74:74:sshd:/var/empty:/bin/false
    ${user}:x:${uid}:${gid}:${user}:/workspace:/bin/bash
  '';
  groupFile = pkgs.writeText "group" ''
    root:x:0:
    sshd:x:74:
    ${user}:x:${gid}:
  '';
  shadowFile = pkgs.writeText "shadow" ''
    root:!:1::::::
    ${user}:*:1::::::
  '';
  nsswitch = pkgs.writeText "nsswitch.conf" ''
    passwd: files
    group:  files
    shadow: files
    hosts:  files dns
  '';
  sshdConfig = pkgs.writeText "sshd_config" ''
    Port 22
    HostKey /etc/ssh/ssh_host_ed25519_key
    AuthorizedKeysFile .ssh/authorized_keys
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    PrintMotd no
    Subsystem sftp internal-sftp
  '';
  nixConf = pkgs.writeText "nix.conf" ''
    experimental-features = nix-command flakes
    build-users-group =
    require-sigs = false
    extra-sandbox-paths = /dev/kvm
  '';

  # Git credential helper — reads token from a file at runtime.
  # Built as a store path so the entrypoint just copies it into place.
  gitCredentialHelper = pkgs.writeShellScript "git-credential-helper" ''
    echo "username=cc"
    echo "password=$(cat /workspace/.config/git/token)"
  '';

  # Nix store registration for the image closure — loaded at boot to populate
  # the Nix DB so `nix develop` can find existing store paths.
  imageContents = [
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
    pkgs.git
    pkgs.nodejs
    pkgs.curl
    pkgs.vim
    pkgs.less
    pkgs.cacert
    pkgs.openssh
    pkgs.claude-code
    pkgs.nix
    # /usr/bin/env for `#!/usr/bin/env ...` shebangs (and /bin/sh)
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
  ];
  closure = pkgs.closureInfo {rootPaths = imageContents;};

  entrypoint = pkgs.writeShellScript "entrypoint.sh" ''
    set -euo pipefail

    # Generate host keys on first start
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
    fi

    # Ensure required directories exist
    mkdir -p /var/empty /run

    # Transfer /dev/kvm ownership to claude if passed in — host device is
    # root:kvm mode 0660, but the container has no kvm group.  Keeping 0660
    # and changing the owner is sufficient and avoids world-write.
    if [ -e /dev/kvm ]; then
      chown ${uid}:${gid} /dev/kvm
    fi

    # Write /etc/resolv.conf from SANDBOX_DNS env var (space-separated IPs)
    if [ -n "''${SANDBOX_DNS:-}" ]; then
      : > /etc/resolv.conf
      for ns in $SANDBOX_DNS; do
        echo "nameserver $ns" >> /etc/resolv.conf
      done
    fi

    # Initialize Nix store DB and register the image closure so `nix develop` works.
    # Single-user mode: the claude user owns the entire /nix tree.
    if [ ! -f /nix/var/nix/db/db.sqlite ]; then
      (
        HOME=/root ${pkgs.nix}/bin/nix-store --init
        HOME=/root ${pkgs.nix}/bin/nix-store --load-db < /nix/nix-registration
        ${pkgs.coreutils}/bin/chown -R ${uid}:${gid} /nix/var
        ${pkgs.coreutils}/bin/chown ${uid}:${gid} /nix/store
      ) &
      nix_init_pid=$!
    fi

    # Set up git credential helper if a token is provided.
    # The token is stored in a file (not in .git/config or the clone URL).
    if [ -n "''${SANDBOX_GIT_TOKEN:-}" ]; then
      mkdir -p /workspace/.config/git
      cp ${gitCredentialHelper} /workspace/.config/git/credential-helper
      echo -n "$SANDBOX_GIT_TOKEN" > /workspace/.config/git/token
      chmod 600 /workspace/.config/git/token
      ${pkgs.coreutils}/bin/chown -R ${uid}:${gid} /workspace/.config
      ${pkgs.git}/bin/git config --system credential.helper /workspace/.config/git/credential-helper
    fi

    # Fix ownership on mounted Claude state directory (bind-mounted from host).
    # The host UID may differ from the container's claude user (1000).
    if [ -d /workspace/.claude ]; then
      ${pkgs.coreutils}/bin/chown -R ${uid}:${gid} /workspace/.claude
    fi

    # Clone repo if SANDBOX_REPO_URL is set (injected by cc-sandbox via deployd env).
    # SANDBOX_REPO_NAME controls the directory name (defaults to "repo").
    # Failure is non-fatal so sshd still starts (allows debugging via SSH).
    if [ -n "''${SANDBOX_REPO_URL:-}" ]; then
      repo_dir="/workspace/''${SANDBOX_REPO_NAME:-repo}"
      if ${pkgs.git}/bin/git clone "$SANDBOX_REPO_URL" "$repo_dir"; then
        # Add upstream remote before chown (both run as root)
        if [ -n "''${SANDBOX_UPSTREAM_URL:-}" ]; then
          ${pkgs.git}/bin/git -C "$repo_dir" remote add upstream "$SANDBOX_UPSTREAM_URL"
        fi
        ${pkgs.coreutils}/bin/chown -R ${uid}:${gid} "$repo_dir"
      else
        echo "WARNING: git clone failed" >&2
      fi
    fi

    # Wait for nix store init before starting sshd
    if [ -n "''${nix_init_pid:-}" ]; then
      wait "$nix_init_pid"
    fi

    # Start sshd in the foreground
    exec ${pkgs.openssh}/bin/sshd -D -e -f /etc/ssh/sshd_config
  '';
in
  pkgs.dockerTools.buildLayeredImage {
    name = "claude-sandbox";
    tag = "latest";

    contents = imageContents;

    extraCommands = ''
      # Set up filesystem structure
      mkdir -p workspace/.ssh tmp var/empty etc/ssh
      chmod 1777 tmp

      # Install user database files
      mkdir -p etc
      cp ${passwdFile} etc/passwd
      cp ${groupFile} etc/group
      cp ${shadowFile} etc/shadow
      cp ${nsswitch} etc/nsswitch.conf

      # sshd config (replace default from openssh package)
      rm -f etc/ssh/sshd_config
      cp ${sshdConfig} etc/ssh/sshd_config

      # Authorized keys for the claude user (home is /workspace)
      echo '${authorizedKeys}' > workspace/.ssh/authorized_keys

      # SSL certs: combine public CAs with internal step-ca root
      mkdir -p etc/ssl/certs
      cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${internalCaCert} > etc/ssl/certs/ca-certificates.crt

      # Nix config: enable flakes + single-user store
      mkdir -p etc/nix
      cp ${nixConf} etc/nix/nix.conf

      # Nix store DB directories + registration file (loaded by entrypoint)
      mkdir -p nix/var/nix/db nix/var/nix/gcroots nix/var/nix/profiles
      cp ${closure}/registration nix/nix-registration
    '';

    # fakeRootCommands runs under fakeroot so chown works
    fakeRootCommands = ''
      chown -R ${uid}:${gid} workspace
      chmod 700 workspace/.ssh
      chmod 600 workspace/.ssh/authorized_keys
      # Pre-set nix directory ownership so entrypoint only chowns runtime db.sqlite
      chown -R ${uid}:${gid} nix/var
    '';

    config = {
      ExposedPorts = {"22/tcp" = {};};
      WorkingDir = "/workspace";
      Env = [
        "HOME=/workspace"
        "USER=${user}"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        "PATH=/bin:/usr/bin"
      ];
      # Run as root — sshd needs root to bind port 22 and read host keys.
      # SSH sessions drop to the claude user via normal sshd privilege separation.
      Cmd = ["${entrypoint}"];
    };
  }
