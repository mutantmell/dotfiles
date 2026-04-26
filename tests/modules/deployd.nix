# Integration test for the deployd module.
#
# Validates that the deployd-helper service, bridge network, and static
# nftables isolation are correctly configured. Does not test Kata
# (unavailable in VM tests) or Caddy route management (requires network).
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  testTokenFile = pkgs.writeText "deployd-test-token" "test-capability-token";

  # Minimal container image for testing deploy/inspect flow.
  # Built at Nix eval time; imported into containerd in the test VM.
  testImage = pkgs.dockerTools.buildImage {
    name = "registry.test/test-app";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "test-env";
      paths = [pkgs.busybox];
    };
    config.Cmd = ["/bin/sleep" "3600"];
  };
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
        # In tests, the vsock socket path is a plain Unix socket; no cloud-hypervisor
        # proxy is involved.  deployd-helper still binds and listens on this path.
        vsockHostSocket = "/run/deployd/deployd.sock";
        capabilityTokenFile = "${testTokenFile}";

        bridge = {
          name = "br-deploy";
          subnet = "10.100.0.0/24";
          gateway = "10.100.0.1";
        };

        # Disable Caddy in basic test
        caddy.enable = false;
      };

      # Test tools
      environment.systemPackages = [
        pkgs.nftables
        pkgs.python3 # for socket protocol tests
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

      # Bridge network device exists
      host.succeed("ip link show br-deploy")

      # Static nftables isolation table is loaded with forward chain drop rule
      host.succeed("nft list table inet container-deploy")
      host.succeed("nft list chain inet container-deploy forward | grep 'drop'")

      # Socket file exists
      host.succeed("test -S /run/deployd/deployd.sock")

      # Log directory exists
      host.succeed("test -d /var/log/deployd")

      # nerdctl and containerd are available
      host.succeed("nerdctl --version")
      host.succeed("containerd --version")

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

      # --- Deploy + Inspect flow ---
      # Import a pre-built test image into containerd and run a container
      # manually (simulating what a deployd systemd unit does), then verify
      # that Inspect returns the container's IP via the ctr + CNI state path.

      host.succeed("ctr -n default images import ${testImage}")
      host.succeed(
          "nerdctl run -d --name=test-inspect --network=br-deploy "
          + "registry.test/test-app:latest"
      )

      # Wait for CNI to assign an IP (host-local IPAM writes state files)
      host.wait_until_succeeds("ls /var/lib/cni/networks/br-deploy/10.* 2>/dev/null", timeout=15)

      # Inspect via deployd-helper socket: should return an IP in 10.100.0.0/24
      host.succeed(
          """
          python3 -c '
      import socket, json

      sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
      sock.connect("/run/deployd/deployd.sock")

      msg = json.dumps({"token": "test-capability-token", "command": {"type": "Inspect", "name": "test-inspect"}})
      sock.sendall((msg + chr(10)).encode())

      data = b""
      while b"\\n" not in data:
          chunk = sock.recv(4096)
          if not chunk:
              break
          data += chunk
      resp = json.loads(data.decode())
      assert resp["success"] is True, f"inspect failed: {resp}"
      ip = resp.get("data", {}).get("ip", "")
      assert ip.startswith("10.100.0."), f"expected 10.100.0.x IP, got: {ip!r}"
      print(f"Inspect returned IP: {ip}")
      sock.close()
      '
          """
      )

      # Verify inspect is logged in audit
      host.succeed("grep '\"Inspect\"' /var/log/deployd/audit.log")

      # Clean up the test container
      host.succeed("nerdctl stop test-inspect >/dev/null 2>&1 || true")
      host.succeed("nerdctl rm -f test-inspect >/dev/null 2>&1 || true")
    '';
  }
