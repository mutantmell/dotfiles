# VM-only smoke test for systemd-networkd link renaming via router6.hardwareName.
#
# Container tests deliberately use kernel interface names directly; nspawn does
# not independently prove the VM/guest link rename path.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-interface-rename-vm";

  nodes.router = {
    imports = [
      ../../modules/router6
      ../lib/test-minimal-base.nix
    ];

    virtualisation.vlans = [1 2];

    router6 = {
      enable = true;
      ulaPrefix = "fdc6:55f2:0a5e::/48";

      zones = {
        external = {
          icmpEcho = "disable";
          accessTo = [];
          inputRules = [];
        };
        trusted = {
          icmpEcho = "enable";
          accessTo = ["external"];
          inputRules = [{verdict = "accept";}];
        };
      };

      topology = {
        wan = {
          hardwareName = "eth1";
          network = {
            type = "static";
            addresses = ["192.0.2.1/24"];
            zone = "external";
          };
        };
        lan = {
          hardwareName = "eth2";
          network = {
            type = "static";
            addresses = ["10.0.10.1/24"];
            zone = "trusted";
          };
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
    router.wait_until_succeeds("ip link show wan", timeout=30)
    router.wait_until_succeeds("ip link show lan", timeout=30)
    router.fail("ip link show eth1")
    router.fail("ip link show eth2")
  '';
}
