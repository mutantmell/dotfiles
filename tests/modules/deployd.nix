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

      # Test tools
      environment.systemPackages = [
        pkgs.nftables
        pkgs.python3  # for socket protocol tests
      ];

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
      host.succeed("test -d /var/log/deployd")

      # Quadlet directories exist (runtime + persistent)
      host.succeed("test -d /run/containers/systemd")
      host.succeed("test -d /etc/containers/systemd")

      # Podman is available
      host.succeed("podman --version")

      # Firewall set manipulation works (add then remove)
      host.succeed("nft add element inet container-deploy allowed_ports { 8080 }")
      host.succeed("nft list set inet container-deploy allowed_ports | grep 8080")
      host.succeed("nft delete element inet container-deploy allowed_ports { 8080 }")

      # Socket protocol: valid Status command returns success
      host.succeed(
          """
          python3 -c '
      import socket, json, os

      sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
      sock.connect("/run/deployd/deployd.sock")

      msg = json.dumps({"token": "test-capability-token", "command": {"type": "Status"}})
      sock.sendall((msg + chr(10)).encode())

      data = b""
      while b"\\n" not in data:
          chunk = sock.recv(4096)
          if not chunk:
              break
          data += chunk
      resp = json.loads(data.decode())
      assert resp["success"] is True, f"expected success, got: {resp}"
      assert "running" in resp["message"], f"unexpected message: {resp}"
      sock.close()
      '
          """
      )

      # Socket protocol: invalid token is rejected
      host.succeed(
          """
          python3 -c '
      import socket, json

      sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
      sock.connect("/run/deployd/deployd.sock")

      msg = json.dumps({"token": "wrong-token", "command": {"type": "Status"}})
      sock.sendall((msg + chr(10)).encode())

      data = b""
      while b"\\n" not in data:
          chunk = sock.recv(4096)
          if not chunk:
              break
          data += chunk
      resp = json.loads(data.decode())
      assert resp["success"] is False, f"expected failure, got: {resp}"
      assert "token" in resp["message"].lower(), f"unexpected message: {resp}"
      sock.close()
      '
          """
      )

      # Audit log is written after socket interactions
      host.succeed("test -f /var/log/deployd/audit.log")
      host.succeed("grep '\"command\":\"Status\"' /var/log/deployd/audit.log")
    '';
  }
