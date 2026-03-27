# OCI image for sandboxed Claude Code environments.
#
# Provides a minimal environment with shell, git, nodejs, and common CLI tools.
# Runs sshd on port 22 with authorized keys from the project key registry.
# Designed to run on the deployd vDMZ network with its own IP.
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

  # Minimal passwd/group for the non-root user
  passwdFile = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/bash
    sshd:x:74:74:sshd:/var/empty:/bin/false
    ${user}:x:${uid}:${gid}:${user}:/home/${user}:/bin/bash
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
    # Generate host keys on first start
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
    fi

    # Ensure required directories exist
    mkdir -p /var/empty /run

    # Clone repo if SANDBOX_REPO_URL is set (injected by cc-sandbox via deployd env)
    if [ -n "''${SANDBOX_REPO_URL:-}" ]; then
      ${pkgs.git}/bin/git clone "$SANDBOX_REPO_URL" /workspace/repo || true
      ${pkgs.coreutils}/bin/chown -R ${uid}:${gid} /workspace/repo
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
      mkdir -p workspace tmp home/${user}/.ssh var/empty etc/ssh
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

      # Authorized keys for the claude user
      echo '${authorizedKeys}' > home/${user}/.ssh/authorized_keys

      # SSL certs
      mkdir -p etc/ssl/certs
      ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
    '';

    # fakeRootCommands runs under fakeroot so chown works
    fakeRootCommands = ''
      chown -R ${uid}:${gid} home/${user}
      chmod 700 home/${user}/.ssh
      chmod 600 home/${user}/.ssh/authorized_keys
      chown -R ${uid}:${gid} workspace
    '';

    config = {
      ExposedPorts = {"22/tcp" = {};};
      WorkingDir = "/workspace";
      Env = [
        "HOME=/home/${user}"
        "USER=${user}"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        "PATH=/bin:/usr/bin"
      ];
      # Run as root — sshd needs root to bind port 22 and read host keys.
      # SSH sessions drop to the claude user via normal sshd privilege separation.
      Cmd = ["${entrypoint}"];
    };
  }
