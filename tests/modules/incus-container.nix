# NixOS integration test for incus-manager container lifecycle
#
# Verifies that the incus-manager module can:
# 1. Import a container image
# 2. Create a container instance
# 3. Start the container
# 4. Add a static disk device and verify file access inside the container
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
      imports = [
        ../../modules/incus
        ../lib/test-minimal-base.nix
      ];

      incus-manager = {
        enable = true;
        guests.testguest = {
          type = "container";
          system = guestSystem;
          autoStart = true;
          staticDir = "/var/lib/testguest-static";
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
      # Create static directory with a test file before incus starts
      # Use /var/lib/ (not /tmp/) — container bind mounts reject "too revealing" paths like /tmp (mode 1777)
      host.succeed("mkdir -p /var/lib/testguest-static/etc/ssh")
      host.succeed("echo 'test-key-content' > /var/lib/testguest-static/etc/ssh/ssh_host_ed25519_key")
      host.succeed("chmod 600 /var/lib/testguest-static/etc/ssh/ssh_host_ed25519_key")

      host.wait_for_unit("incus.service")
      host.wait_for_unit("incus-ensure-instances.service")

      # Verify the image was imported
      host.succeed("incus image list --format=csv -c l | grep -q testguest")

      # Verify the instance exists and is running
      host.succeed("incus list --format=csv -c ns | grep -q 'testguest,RUNNING'")

      # Verify we can execute commands inside the container
      host.succeed("incus exec testguest -- hostname | grep -q testguest")

      # Verify the static disk device was added
      host.succeed("incus config device list testguest | grep -q '^static$'")

      # Verify the static directory is mounted and SSH key is readable inside the container
      host.succeed("incus exec testguest -- cat /static/etc/ssh/ssh_host_ed25519_key | grep -q test-key-content")
    '';
  }
