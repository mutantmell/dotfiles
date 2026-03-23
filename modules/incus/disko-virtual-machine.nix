# Drop-in replacement for nixpkgs' incus-virtual-machine.nix that delegates
# disk layout and image building to disko instead of make-disk-image.nix.
#
# Provides everything incus-virtual-machine.nix provides except:
# - fileSystems (disko owns these)
# - system.build.qemuImage (replaced by system.build.diskoImages)
#
# Keeps:
# - lxc-instance-common.nix (Incus metadata tarball: system.build.metadata)
# - qemu-guest.nix (virtio kernel modules)
# - Boot config (systemd-boot, grub device, growPartition)
# - Incus agent
# - Serial console and CPU hotplug
{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    "${modulesPath}/virtualisation/lxc-instance-common.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  config = {
    boot.growPartition = true;
    boot.loader.systemd-boot.enable = true;

    # Image building needs to know what device to install bootloader on
    boot.loader.grub.device = "/dev/vda";

    boot.kernelParams = [
      "console=tty1"
      "console=ttyS0"
    ];

    # CPU hotplug
    services.udev.extraRules = ''
      SUBSYSTEM=="cpu", CONST{arch}=="x86-64", TEST=="online", ATTR{online}=="0", ATTR{online}="1"
    '';

    virtualisation.incus.agent.enable = lib.mkDefault true;
  };
}
