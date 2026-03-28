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

  keys = builtins.fromJSON (builtins.readFile ../../lib/common/data/keys.json);
  authorizedKeys = builtins.concatStringsSep "\n" [
    keys.ssh.deploy
    keys.ssh.home
    keys.ssh.edith
  ];

  # Internal step-ca root certificate for TLS to creil.internal, etc.
  internalCaCert = ../../lib/common/data/pki/root_ca.crt;

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

  entrypoint = pkgs.writeShellScript "entrypoint.sh" ''
    set -euo pipefail

    # Generate host keys on first start
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
    fi

    # Ensure required directories exist
    mkdir -p /var/empty /run

    # Write /etc/resolv.conf from SANDBOX_DNS env var (space-separated IPs)
    if [ -n "''${SANDBOX_DNS:-}" ]; then
      : > /etc/resolv.conf
      for ns in $SANDBOX_DNS; do
        echo "nameserver $ns" >> /etc/resolv.conf
      done
    fi

    # Clone repo if SANDBOX_REPO_URL is set (injected by cc-sandbox via deployd env).
    # Failure is non-fatal so sshd still starts (allows debugging via SSH).
    if [ -n "''${SANDBOX_REPO_URL:-}" ]; then
      if ${pkgs.git}/bin/git clone "$SANDBOX_REPO_URL" /workspace/repo; then
        ${pkgs.coreutils}/bin/chown -R ${uid}:${gid} /workspace/repo
      else
        echo "WARNING: git clone failed (exit $?)" >&2
      fi
    fi

    # Install Claude Code (latest version, needs nodejs + npm from image).
    # Failure is non-fatal so sshd still starts.
    if HOME=/tmp NPM_CONFIG_PREFIX=/workspace/.npm-global \
        ${pkgs.nodejs}/bin/npm install -g @anthropic-ai/claude-code; then
      ${pkgs.coreutils}/bin/chown -R ${uid}:${gid} /workspace/.npm-global
    else
      echo "WARNING: claude code install failed (exit $?)" >&2
    fi

    # Start sshd in the foreground
    exec ${pkgs.openssh}/bin/sshd -D -e -f /etc/ssh/sshd_config
  '';
in
  pkgs.dockerTools.buildLayeredImage {
    name = "claude-sandbox";
    tag = "latest";

    contents = [
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
    ];

    extraCommands = ''
      # Set up filesystem structure
      mkdir -p workspace/.ssh workspace/.npm-global/bin tmp var/empty etc/ssh
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

      # Bash profile: add npm-global binaries to PATH
      cat > workspace/.bashrc << 'BASHRC'
      export PATH="/workspace/.npm-global/bin:$PATH"
      BASHRC
    '';

    # fakeRootCommands runs under fakeroot so chown works
    fakeRootCommands = ''
      chown -R ${uid}:${gid} workspace
      chmod 700 workspace/.ssh
      chmod 600 workspace/.ssh/authorized_keys
    '';

    config = {
      ExposedPorts = {"22/tcp" = {};};
      WorkingDir = "/workspace";
      Env = [
        "HOME=/workspace"
        "USER=${user}"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        "PATH=/workspace/.npm-global/bin:/bin:/usr/bin"
      ];
      # Run as root — sshd needs root to bind port 22 and read host keys.
      # SSH sessions drop to the claude user via normal sshd privilege separation.
      Cmd = ["${entrypoint}"];
    };
  }
