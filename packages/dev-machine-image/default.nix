{
  nixpkgs,
  system ? "x86_64-linux",
  # Extra CA certificates (PEM paths) added to the guest trust store. The base
  # config is host-agnostic, but in practice the VM must trust creil's step-ca to
  # clone the workspace over HTTPS and to pull the dev image from
  # forgejo.internal. Injected here at the flake boundary so configuration.nix
  # stays standalone (cf. how the dev image takes claude-code as a param).
  caCerts ? [],
}: let
  inherit (nixpkgs) lib;

  # The thin base NixOS (configuration.nix). Standalone nixosSystem so the image
  # stays host-agnostic and free of impermanence/sops/registry coupling. Pinned
  # to x86_64-linux by the config's hostPlatform, so this package always builds
  # an x86_64 guest regardless of which `packages.<system>` attr exposes it.
  baseSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      ./configuration.nix
      {security.pki.certificateFiles = caCerts;}
    ];
  };

  inherit (baseSystem) pkgs;

  # Bootable qcow2 (MBR/BIOS grub at /dev/vda) built from the thin config. The
  # result is $out/nixos.qcow2. Kept small — diskSize "auto" sizes to the closure
  # plus a little slack; the root fs auto-resizes into the runtime overlay, so
  # OCI layers / the devcontainer build live there, not baked into the image.
  diskImage = import (nixpkgs + "/nixos/lib/make-disk-image.nix") {
    inherit pkgs lib;
    inherit (baseSystem) config;
    format = "qcow2";
    partitionTableType = "legacy";
    # Root holds only the base OS. Podman's rootful storage (the dev image + every
    # in-container build, incl. nixosTest VM images) lives on a separate ephemeral
    # scratch disk — see configuration.nix's /var/lib/containers mount + the VMI's
    # emptyDisk — so "auto" (closure-sized) is right and the disk-image build stays
    # small and fast (a large diskSize OOM-panics the make-disk-image builder VM).
    diskSize = "auto";
    installBootLoader = true;
  };
in
  # KubeVirt containerDisk: a scratch-style OCI image carrying the VM disk under
  # /disk/ (the path KubeVirt boots, as a copy-on-write overlay — no CSI needed,
  # decision 3). `streamLayeredImage` so it can be `skopeo copy`'d to creil
  # without a container daemon; the push itself is an operator/CI step (Phase 2),
  # not done here. uid/gid 107 is KubeVirt's `qemu` container user.
  pkgs.dockerTools.streamLayeredImage {
    name = "dev-machine-base";
    tag = "latest";
    fakeRootCommands = ''
      mkdir -p disk
      cp ${diskImage}/nixos.qcow2 disk/boot.qcow2
      chown -R 107:107 disk
    '';
  }
