# Integration test for the deployd module.
#
# Validates that the deployd-helper service, bridge network, and nftables
# table are correctly configured. Does not test Kata (unavailable in VM tests)
# or Caddy route management (requires network).
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  testTokenFile = pkgs.writeText "deployd-test-token" "test-capability-token";
in
  pkgs.testers.nixosTest {
    name = "deployd";

    nodes.host = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [../../modules/deployd];

      # Enable systemd-networkd (required for bridge)
      networking.useNetworkd = true;
      networking.useDHCP = false;

      deployd = {
        enable = true;
        registryAllowlist = ["registry.test"];
        hostnameAllowlist = [".test.internal"];
        socketPath = "/run/deployd/deployd.sock";
        capabilityTokenFile = "${testTokenFile}";
        allowedUid = 1000;

        bridge = {
          name = "br-deploy";
          subnet = "10.100.0.1/24";
        };

        # Disable Kata in test VM (no nested KVM)
        kata.enable = false;

        # Disable Caddy in basic test
        caddy.enable = false;
      };

      # nft CLI for test assertions
      environment.systemPackages = [pkgs.nftables];

      # Test VM needs more resources
      virtualisation = {
        memorySize = 1024;
        cores = 2;
      };
    };

    testScript = ''
      host.wait_for_unit("multi-user.target")

      # Wait for deployd-helper (depends on networkd, ensures bridge is configured)
      host.wait_for_unit("deployd-helper.service")

      # Bridge network device exists with correct address
      host.succeed("ip link show br-deploy")
      host.succeed("ip -4 addr show dev br-deploy | grep '10.100.0.1'")
      host.succeed("networkctl status br-deploy | grep -q 'State.*routable\|configured'")

      # nftables table is loaded
      host.succeed("nft list table inet container-deploy")
      host.succeed("nft list set inet container-deploy allowed_ports")

      # Socket file exists
      host.succeed("test -S /run/deployd/deployd.sock")

      # State directories exist
      host.succeed("test -d /var/lib/deployd")
      host.succeed("test -d /var/lib/deployd/quadlets")
      host.succeed("test -d /var/log/deployd")

      # Quadlet runtime directory exists
      host.succeed("test -d /run/containers/systemd")

      # Podman is available
      host.succeed("podman --version")

      # Firewall set manipulation works (add then remove)
      host.succeed("nft add element inet container-deploy allowed_ports { 8080 }")
      host.succeed("nft list set inet container-deploy allowed_ports | grep 8080")
      host.succeed("nft delete element inet container-deploy allowed_ports { 8080 }")
    '';
  }
