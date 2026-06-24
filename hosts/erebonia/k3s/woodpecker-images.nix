{
  pkgs,
  nixpkgs,
}: let
  pki = pkgs.mmell.lib.data.pki;
  uid = 1000;
  gid = 1000;
  internalCaBundle = pkgs.runCommand "internal-ca-bundle.crt" {} ''
    cat ${pki.root} ${pki.intermediate} > "$out"
  '';
  ciWorkerImage = import ../../../packages/ci-worker-image {
    inherit nixpkgs;
    system = pkgs.stdenv.hostPlatform.system;
    caCerts = with pki; [root intermediate];
  };
  pluginGitImage = pkgs.dockerTools.pullImage {
    imageName = "docker.io/woodpeckerci/plugin-git";
    imageDigest = "sha256:8995e4745cf57dcee659db94d43598fd181b1b370671db2c9ccf7b0b2a8f31c8";
    hash = "sha256-62wLzNXA+U4I6r1b8tf2zIL3mi4Gf1hXeLmWhdPbTjE=";
    finalImageName = "docker.io/woodpeckerci/plugin-git";
    finalImageTag = "2.9.1";
  };
in {
  agent = pkgs.dockerTools.pullImage {
    imageName = "docker.io/woodpeckerci/woodpecker-agent";
    imageDigest = "sha256:aecf04600c2f19c7ea79202177fadda8b8331d105ed981f0a8fd4725cf1df9e7";
    hash = "sha256-iClWLAbN0tsCyQ0B67IXVKqDAUxAmZmA4W5USd9Bsu8=";
    finalImageName = "docker.io/woodpeckerci/woodpecker-agent";
    finalImageTag = "v3.15.0";
  };

  pluginGit = pluginGitImage;

  pluginGitInternalCa = pkgs.dockerTools.buildImage {
    fromImage = pluginGitImage;
    name = "localhost/woodpecker-plugin-git";
    tag = "2.9.1-internal-ca";
    copyToRoot = pkgs.runCommand "woodpecker-plugin-git-internal-ca-root" {} ''
      mkdir -p "$out/etc/ssl/certs"
      cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${internalCaBundle} > "$out/etc/ssl/certs/ca-certificates.crt"
      cp "$out/etc/ssl/certs/ca-certificates.crt" "$out/etc/ssl/certs/ca-bundle.crt"
    '';
    config = {
      Entrypoint = ["/bin/plugin-git"];
      WorkingDir = "/";
      Env = [
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        "GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt"
      ];
    };
  };

  busybox = pkgs.dockerTools.pullImage {
    imageName = "docker.io/library/busybox";
    imageDigest = "sha256:cbf412bcf1379481c80f65208703910fe543b3a948ae74a32a10ca3789dc13ab";
    hash = "sha256-lNRjxvfaVXfZzF6ddywsu1ybV+QRwjTo/BKvSb3DDbY=";
    finalImageName = "busybox";
    finalImageTag = "stable-musl";
  };

  ciWorker = ciWorkerImage;

  dotfilesCiNix = pkgs.dockerTools.buildLayeredImageWithNixDb {
    name = "localhost/dotfiles-ci-nix";
    # Bump this tag whenever the image runtime contents or filesystem metadata
    # change; k3s/containerd may keep serving an existing node-local tag.
    tag = "0.1.3";

    contents = with pkgs; [
      alejandra
      bashInteractive
      cacert
      coreutils-full
      curl
      diffutils
      dockerTools.usrBinEnv
      file
      findutils
      gawk
      gitMinimal
      gnugrep
      gnused
      gnutar
      gzip
      jq
      nix
      openssh
      openssl
      patch
      pkg-config
      skopeo
      treefmt
      util-linux
      which
      xz
    ];

    inherit uid;
    inherit gid;
    uname = "ci";
    gname = "ci";

    config = {
      Cmd = ["/bin/bash"];
      User = "ci";
      WorkingDir = "/workspace";
      Env = [
        "PATH=/bin"
        "USER=ci"
        "HOME=/tmp"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
        "NIX_PATH=nixpkgs=flake:nixpkgs"
      ];
    };

    fakeRootCommands = ''
      mkdir -p etc/nix etc/ssl/certs tmp workspace nix/var/log/nix/drvs nix/var/nix/gcroots/per-user/ci nix/var/nix/profiles/per-user/ci nix/var/nix/temproots
      chmod 1777 tmp
      chown ${toString uid}:${toString gid} workspace
      chown ${toString uid}:${toString gid} nix/store
      chown ${toString uid}:${toString gid} nix/store/.links
      chown -R ${toString uid}:${toString gid} nix/var
      cat > etc/passwd <<EOF
      root:x:0:0:root:/root:/bin/bash
      ci:x:${toString uid}:${toString gid}:ci:/tmp:/bin/bash
      nobody:x:65534:65534:nobody:/var/empty:/bin/false
      EOF
      cat > etc/group <<EOF
      root:x:0:
      ci:x:${toString gid}:
      nobody:x:65534:
      EOF
      cat > etc/nsswitch.conf <<EOF
      passwd: files
      group: files
      hosts: files dns
      EOF
      cp -L --remove-destination ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-bundle.crt
      cp -L --remove-destination ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
      cat > etc/nix/nix.conf <<EOF
      experimental-features = nix-command flakes
      sandbox = false
      build-users-group =
      max-jobs = 1
      cores = 2
      EOF
    '';
  };
}
