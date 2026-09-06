{
  nixpkgs,
  system ? "x86_64-linux",
  claude-code ? null,
  codex ? null,
  opencode ? null,
  role ? "dev-machine",
  imageName ? "dev-machine-base",
  # Extra CA certificates (PEM paths) added to the guest trust store. The base
  # config is host-agnostic, but in practice the VM must trust creil's step-ca to
  # clone the workspace over HTTPS and to pull internal images from
  # forgejo.internal. Injected here at the flake boundary so configuration.nix
  # stays standalone.
  caCerts ? [],
}: let
  inherit (nixpkgs) lib;

  validRoles = ["dev-machine" "ci-worker"];

  # The base NixOS (configuration.nix). Standalone nixosSystem so the image stays
  # host-agnostic and free of impermanence/sops/registry coupling. It includes
  # the host nix-daemon policy and the dev-tool closure the devcontainer reaches
  # through the bind-mounted host /nix. Pinned to x86_64-linux by the config's
  # hostPlatform, so this package always builds an x86_64 guest regardless of
  # which `packages.<system>` attr exposes it.
  baseSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit claude-code codex opencode role;
    };
    modules = [
      ./configuration.nix
      {security.pki.certificateFiles = caCerts;}
    ];
  };

  inherit (baseSystem) pkgs;

  # Bootable qcow2 (MBR/BIOS grub at /dev/vda) built from the base config. The
  # result is $out/nixos.qcow2. Kept small — diskSize "auto" sizes to the closure
  # plus a little slack; the root fs auto-resizes into the runtime overlay, so
  # OCI layers / the devcontainer build live there, not baked into the image.
  diskImage = import (nixpkgs + "/nixos/lib/make-disk-image.nix") {
    inherit pkgs lib;
    inherit (baseSystem) config;
    format = "qcow2";
    partitionTableType = "legacy";
    # Root holds the seed copy of the base OS, host nix-daemon, and dev-tool
    # closure. At runtime, configuration.nix copies /nix onto the separate
    # ephemeral scratch disk and bind-mounts it back before nix-daemon starts, so
    # "auto" keeps the image closure-sized and avoids the large diskSize
    # OOM-panic path in make-disk-image.
    diskSize = "auto";
    installBootLoader = true;
  };
in
  # KubeVirt containerDisk: a scratch-style OCI image carrying the VM disk under
  # /disk/ (the path KubeVirt boots, as a copy-on-write overlay — no CSI needed,
  # decision 3). `streamLayeredImage` so it can be `skopeo copy`'d to creil
  # without a container daemon; the push itself is an operator/CI step (Phase 2),
  # not done here. uid/gid 107 is KubeVirt's `qemu` container user.
  assert lib.assertMsg (builtins.elem role validRoles) "dev-machine-image: role must be one of ${builtins.concatStringsSep ", " validRoles}";
    pkgs.dockerTools.streamLayeredImage {
      name = imageName;
      tag = "latest";
      fakeRootCommands = ''
        mkdir -p disk
        cp ${diskImage}/nixos.qcow2 disk/boot.qcow2
        chown -R 107:107 disk
      '';
    }
