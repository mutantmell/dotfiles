# Placeholder — replace with output of nixos-generate-config at install time.
# Filesystem declarations are handled by disko.nix.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = ["xhci_pci" "nvme" "usb_storage" "sd_mod"];
  boot.kernelModules = ["kvm-intel"];
}
