# NixOS integration test for incus-manager container lifecycle
#
# Verifies that the incus-manager module can:
# 1. Import a container image
# 2. Create a container instance
# 3. Start the container
# 4. Execute commands inside the container
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix");

  # Minimal container guest NixOS config
  guestConfig = {
    config,
    pkgs,
    lib,
    ...
  }: {
    networking.hostName = "testguest";
    system.stateVersion = "25.11";
  };

  # Build a container system using the standard NixOS container module
  guestSystem = evalConfig {
    system = "x86_64-linux";
    modules = [
      guestConfig
      "${pkgs.path}/nixos/modules/virtualisation/lxc-container.nix"
    ];
  };
in
  pkgs.testers.nixosTest {
    name = "incus-container";

    nodes.host = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [../../modules/incus];

      incus-manager = {
        enable = true;
        guests.testguest = {
          type = "container";
          system = guestSystem;
          autoStart = true;
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
        diskSize = 4096;
      };
    };

    testScript = ''
      host.wait_for_unit("incus.service")
      host.wait_for_unit("incus-ensure-instances.service")

      # Verify the image was imported
      host.succeed("incus image list --format=csv -c l | grep -q testguest")

      # Verify the instance exists and is running
      host.succeed("incus list --format=csv -c ns | grep -q 'testguest,RUNNING'")

      # Verify we can execute commands inside the container
      host.succeed("incus exec testguest -- hostname | grep -q testguest")
    '';
  }
