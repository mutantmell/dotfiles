# VM-only smoke test for loading batman-adv in the guest kernel.
#
# Container tests can validate the resulting topology, but module loading is a
# host-kernel concern under nspawn.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-batman-module-vm";

  nodes.router = {
    imports = [
      ../../modules/router6
      ../lib/test-minimal-base.nix
    ];

    boot.kernelModules = ["batman_adv"];
    environment.systemPackages = [pkgs.kmod];
    virtualisation.vlans = [1];

    router6 = {
      enable = true;
      ulaPrefix = "fdc6:55f2:0a5e::/48";

      zones.trusted = {
        icmpEcho = "enable";
        accessTo = [];
        inputRules = [{verdict = "accept";}];
      };

      topology = {
        eth1 = {
          kind = "physical";
          network = {
            type = "disabled";
            mtu = 1536;
          };
        };
        bat0 = {
          kind = "batman";
          members = ["eth1"];
          batman = {
            gatewayMode = "off";
            routingAlgorithm = "batman-v";
          };
          network.type = "disabled";
        };
      };
    };

    services.kresd.enable = lib.mkForce false;
    services.kea.dhcp4.enable = lib.mkForce false;
    services.kea.dhcp6.enable = lib.mkForce false;
  };

  testScript = ''
    start_all()
    router.wait_for_unit("systemd-networkd.service")
    router.succeed("lsmod | grep batman_adv")
    router.wait_until_succeeds("ip link show bat0", timeout=30)
    router.succeed("ip link show eth1 | grep 'master bat0'")
  '';
}
