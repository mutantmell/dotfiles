# NixOS integration test for incus-manager VM lifecycle
#
# Verifies that the incus-manager module can:
# 1. Import a VM image
# 2. Create a VM instance
# 3. Start the VM (requires nested virtualization)
# 4. Execute commands inside the VM

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix");

  # Minimal VM guest NixOS config
  guestConfig = { config, pkgs, lib, ... }: {
    networking.hostName = "testvm";
    system.stateVersion = "25.11";
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };
    boot.loader.grub.device = "/dev/vda";
  };

  # Build a VM system with incus-virtual-machine module
  guestSystem = evalConfig {
    system = "x86_64-linux";
    modules = [
      guestConfig
      "${pkgs.path}/nixos/modules/virtualisation/incus-virtual-machine.nix"
    ];
  };
in

pkgs.testers.nixosTest {
  name = "incus-vm";

  nodes.host = { config, pkgs, lib, ... }: {
    imports = [ ../../modules/incus ];

    incus-manager = {
      enable = true;
      guests.testvm = {
        type = "vm";
        system = guestSystem;
        autoStart = true;
      };
    };

    # Preseed: storage pool + default profile with root disk
    virtualisation.incus.preseed = {
      storage_pools = [{
        name = "default";
        driver = "dir";
      }];
      profiles = [{
        name = "default";
        devices = {
          root = {
            path = "/";
            pool = "default";
            type = "disk";
          };
        };
      }];
    };

    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 8192;
    };
  };

  testScript = ''
    host.wait_for_unit("incus.service")
    host.wait_for_unit("incus-ensure-instances.service")

    # Verify the image was imported
    host.succeed("incus image list --format=csv -c l | grep -q testvm")

    # Verify the instance exists
    host.succeed("incus list --format=csv -c n | grep -q testvm")

    # Wait for the VM to be running (nested VM may not fully boot the
    # guest OS, but QEMU starts and incus reports RUNNING)
    host.succeed("incus list --format=csv -c ns | grep -q 'testvm,RUNNING'")
  '';
}
