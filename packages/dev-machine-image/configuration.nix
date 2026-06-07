{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  # ── Phase 1.3 — thin base VM image for the locked-down LLM dev machines ──────
  # (ai-dev-machine-kubevirt-plan.md). This is the KubeVirt VM that is the
  # security boundary: a deliberately thin NixOS carrying ONLY what devpod's SSH
  # provider needs — sshd, docker, and a service user in the docker group. The
  # actual dev tooling lives in the devcontainer image (Phase 2), which devpod
  # builds/runs as a plain runc container inside this VM. VM = boundary + docker
  # + sshd; nothing else belongs here.
  #
  # Standalone NixOS (NOT mk-nixos): no impermanence, no sops, no host registry —
  # the plan requires this image be thin and host-agnostic.
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    (modulesPath + "/profiles/headless.nix")
    (modulesPath + "/profiles/minimal.nix")
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # MBR/BIOS grub on the disk make-disk-image hands us at /dev/vda — KubeVirt's
  # default q35 + SeaBIOS boots this with no firmware config on the VMI. The root
  # partition is labeled `nixos` and auto-grows into whatever the containerDisk
  # overlay provides.
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };
  boot.loader.timeout = lib.mkForce 1;
  boot.growPartition = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  # Runtime scratch — a KubeVirt emptyDisk (ephemeral, sized at the VMI). docker's
  # data-root lives here, so the dev image and every in-container build (incl.
  # nixosTest VM images) get the space while the OS root stays small. Formatted on
  # first boot; the VMI sets the disk serial "scratch" for a stable by-id name.
  # systemd-makefs (autoFormat) + the mount are ordered before docker via local-fs.
  fileSystems."/var/lib/docker" = {
    device = "/dev/disk/by-id/virtio-scratch";
    fsType = "ext4";
    autoFormat = true;
  };

  # Serial console — `virtctl console` attaches to ttyS0.
  boot.kernelParams = ["console=ttyS0"];

  # Debug affordance: root autologin on the (serial) console. The VM is reachable
  # ONLY via `virtctl console` (cluster/operator access) and is a disposable
  # sandbox, so an unauthenticated serial shell is acceptable — and necessary to
  # diagnose boot/sshd/network issues, since root has no password and `dev` is
  # key-only. Revisit once the path is solid.
  services.getty.autologinUser = lib.mkDefault "root";

  # KubeVirt `masquerade` binding hands the VM a DHCP lease on its single virtio
  # NIC; the namespace NetworkPolicy (Phase 5) governs its egress.
  networking.useDHCP = lib.mkForce true;
  networking.firewall.allowedTCPPorts = [22];

  # ── What devpod's SSH provider needs, and nothing else ──────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # SSH-key injection: KubeVirt AccessCredentials with the `qemuGuestAgent`
  # propagation method drops the operator's pubkey into `dev`'s authorized_keys
  # at VM-create time (and can rotate it live). The guest agent is wanted anyway
  # — KubeVirt uses it for VMI status (IP/OS reporting), graceful shutdown, and
  # `virtctl` console/fs ops. cloud-init is deliberately NOT used: on a
  # declarative NixOS boundary VM its only non-redundant job is key injection
  # (which this covers), and it would add Python + a multi-stage boot to an image
  # we want thin and fast to cold-start. Any real VM-level first-boot need later
  # is a small, local re-add of a cloudInitNoCloud path.
  services.qemuGuest.enable = true;

  # The container runtime devpod's SSH provider targets natively (docker socket +
  # `docker` group). Rootless isn't needed — the VM is the boundary (decision 4).
  virtualisation.docker = {
    enable = true;
    # Use containerd's image store rather than the legacy graphdriver: enables
    # BuildKit's registry cache + lazy pulls (devpod warns when it's off) and
    # writes /etc/docker/daemon.json declaratively, silencing devpod's "could not
    # find docker daemon config file" notice. It's the direction docker is heading
    # (default in newer releases) and fits pulling/caching the devcontainer image.
    daemon.settings.features.containerd-snapshotter = true;
  };

  # The service user devpod targets: passwordless SSH (key injected at runtime)
  # and the `docker` group so the provider can build/run the devcontainer. That
  # is the whole job — devpod injects its agent over SSH into the user's own
  # home/tmp and drives the inner container via the docker socket, so NO sudo is
  # needed. Deliberately no `wheel`: the VM is the security boundary, and giving
  # `dev` passwordless root would hand it to anything that escaped the inner
  # runc container to this user — the opposite of the lockdown intent.
  users.users.dev = {
    isNormalUser = true;
    extraGroups = ["docker"];
  };

  # devpod's SSH provider clones the workspace repo on the agent HOST (this VM)
  # before handing off to the devcontainer, so it needs `git` here — without it
  # devpod tries (and fails) to apt/apk-install it. This is the one dev tool the
  # base carries; the actual toolchain lives in the devcontainer image.
  environment.systemPackages = [pkgs.git];

  # Keep the closure lean — this is a disposable sandbox base, not a workstation.
  documentation.enable = lib.mkForce false;

  system.stateVersion = "25.11";
}
