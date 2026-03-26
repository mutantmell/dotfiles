# NixOS integration test for incus-manager VM lifecycle
#
# Verifies that the incus-manager module can:
# 1. Import a disko-built VM image
# 2. Create a VM instance
# 3. Add a static disk device to the VM
#
# Note: This test does NOT verify the nested VM boots — that requires nested
# virtualization and significantly more resources. We only verify the image
# import, instance creation, and device attachment work correctly.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
  # disko flake input, passed from the flake checks so we avoid builtins.getFlake
  # in a pure nix store evaluation context
  disko,
}: let
  nixosSystem = import (pkgs.path + "/nixos/lib/eval-config.nix");

  # Minimal VM guest NixOS config — keep it as small as possible
  guestConfig = {
    config,
    pkgs,
    lib,
    ...
  }: {
    networking.hostName = "testvm";
    system.stateVersion = "25.11";
    # Minimize closure size
    documentation.enable = false;
  };

  # Build a VM system with disko-virtual-machine module
  guestSystem = nixosSystem {
    system = "x86_64-linux";
    modules = [
      guestConfig
      disko.nixosModules.disko
      ../../modules/incus/disko-virtual-machine.nix
      (import ../../profiles/disko/incus-vm.nix {})
    ];
  };
in
  pkgs.testers.nixosTest {
    name = "incus-vm";

    nodes.host = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [../../modules/incus];

      incus-manager = {
        enable = true;
        guests.testvm = {
          type = "vm";
          system = guestSystem;
          autoStart = false;
          staticDir = "/var/lib/testvm-static";
        };
      };

      # Preseed: storage pool + default profile with root disk
      virtualisation.incus.preseed = {
        storage_pools = [
          {
            name = "default";
            driver = "dir";
          }
        ];
        profiles = [
          {
            name = "default";
            devices = {
              root = {
                path = "/";
                pool = "default";
                type = "disk";
              };
            };
          }
        ];
      };

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 8192;
      };
    };

    testScript = ''
      # Create static directory with a test file before incus starts
      host.succeed("mkdir -p /var/lib/testvm-static/etc/ssh")
      host.succeed("echo 'test-key-content' > /var/lib/testvm-static/etc/ssh/ssh_host_ed25519_key")

      host.wait_for_unit("incus.service")
      host.wait_for_unit("incus-ensure-instances.service")

      # Verify the image was imported
      host.succeed("incus image list --format=csv -c l | grep -q testvm")

      # Verify the instance exists
      host.succeed("incus list --format=csv -c n | grep -q testvm")

      # Verify the instance was created (STOPPED since autoStart = false)
      host.succeed("incus list --format=csv -c ns | grep -q 'testvm,STOPPED'")

      # Verify the static disk device was added
      host.succeed("incus config device list testvm | grep -q '^static$'")
    '';
  }
