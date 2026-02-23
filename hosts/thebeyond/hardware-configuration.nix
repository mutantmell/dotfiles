# Hardware configuration for thebeyond
# This file will be regenerated after nixos-anywhere deployment with:
#   nixos-generate-config --no-filesystems --show-hardware-config
#
# Note: Filesystem configuration is handled by disko (profiles/disko/router.nix)
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "usb_storage" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Filesystem configuration removed - handled by disko
  # Will be regenerated after deployment

  swapDevices = [ ];

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
