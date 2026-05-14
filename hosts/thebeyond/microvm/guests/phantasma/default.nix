{
  pkgs,
  config,
  lib,
  ...
}: let
  hostname = "phantasma";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./modules/dns.nix
    # TODO: Re-enable after thebeyond hardware is deployed (phantasma runs on thebeyond)
    # ./modules/proxy.nix
  ];

  networking.hostName = hostname;

  common.openssh = {
    enable = true;
    keys = ["deploy" "edith"];
  };
  services.openssh.hostKeys = [
    {
      path = "/static/etc/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];

  # cloud-hypervisor's `console=ttyS0` triggers systemd-getty-generator to
  # create serial-getty@ttyS0.service, which waits on dev-ttyS0.device.
  # udev never tags the device in this hypervisor's serial path, so the unit
  # times out after 90s every boot — enough to push past the host service's
  # TimeoutStartSec on fresh deploys. We don't use serial login anyway.
  # Same hazard applies to hvc0 (cloud-hypervisor virtio-console): the
  # generator auto-creates serial-getty@hvc0 which then waits on a
  # dev-hvc0.device that never tags, blocking stage-2 udev for ~90s.
  systemd.services."serial-getty@ttyS0".enable = lib.mkForce false;
  systemd.services."serial-getty@hvc0".enable = lib.mkForce false;

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:0A:AD:01:00:0A";
    networkConfig = {
      Address = [host.cidr4 host.cidr6];
      Gateway = zone.gateway4;
      DNS = ["127.0.0.1"]; # Use local DNS (Blocky -> Unbound)
      # Static v4 and v6 addresses + explicit routes — we don't need RA.
      # Leaving IPv6AcceptRA on stalls systemd-networkd-wait-online for
      # ~2 minutes if no router advertises on brMGMT yet.
      IPv6AcceptRA = false;
      DHCP = "no";
    };
    # Only require IPv4 to consider the interface "online". With static
    # IPv6 + no RA we don't want wait-online to gate boot on v6 SLAAC.
    linkConfig = {
      RequiredForOnline = "routable";
      RequiredFamilyForOnline = "ipv4";
    };
    routes = [
      {Gateway = zone.gateway4;}
      {Gateway = zone.gateway6;}
    ];
  };

  networking.extraHosts =
    ''
      ${zone.gateway4} thebeyond.internal.mutantmell.net thebeyond.internal
      ${zone.gateway6} thebeyond.internal.mutantmell.net thebeyond.internal
    ''
    + net.mkExtraHosts ["messeldam" "basel" "langport"];

  time.timeZone = "UTC";
  security.pki.certificates = [(builtins.readFile pkgs.mmell.lib.data.pki.root)];

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      {
        directory = "/var/lib/acme";
        user = "acme";
        group = "acme";
      }
      "/var/lib/private/blocky" # Blocky state (DynamicUser backing dir)
    ];
  };

  fluent-bit-agent.enable = true;
  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
