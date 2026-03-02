# Shared OpenWrt network topology data
#
# IP addressing, VLAN definitions, and shared config used by all OpenWrt
# device declarations and the image builder pipeline.
{ lib }:

let
  keys = builtins.fromJSON (builtins.readFile ./keys.json);
  # Release pins and Image Builder hashes — updated by `nix run .#openwrt-build -- --update-pins`
  pins = builtins.fromJSON (builtins.readFile ./openwrt-hashes.json);
in
{
  # Default OpenWrt release for all devices (can be overridden per-device).
  # Managed in openwrt-hashes.json — use `nix run .#openwrt-build -- --update-pins` to update.
  defaultRelease = pins.defaultRelease;

  # SHA-256 hashes for OpenWrt Image Builder tarballs, keyed by release then
  # "target/subtarget". Managed in openwrt-hashes.json.
  imageBuilderHashes = pins.imageBuilderHashes;

  # IP prefixes - each device gets one address per prefix for migration compatibility
  ipPrefixes = [ "10.0" "10.1" "10.97" ];

  # Generate list of CIDR addresses for a given VLAN and host ID across all prefixes
  mkAddresses = vlanId: hostId:
    map (p: "${p}.${toString vlanId}.${toString hostId}/24") [ "10.0" "10.1" "10.97" ];

  # Gateway is always on the primary prefix (10.0)
  mkGateway = vlanId: "10.0.${toString vlanId}.1";

  # Router gateway addresses — split so DHCP only binds to the primary (10.0) interface.
  # dnsmasq derives pools from the UCI interface address, so keeping 10.1 and 10.97
  # on a separate _x alias prevents them from getting their own DHCP pools.
  mkPrimaryGatewayAddress = vlanId: "10.0.${toString vlanId}.1/24";
  mkExtraGatewayAddresses = vlanId: [
    "10.1.${toString vlanId}.1/24"
    "10.97.${toString vlanId}.1/24"
  ];

  # Router VLANs — subset of network for temporary router deployment
  # trunkPorts carry all VLANs tagged; accessPorts get untagged traffic
  routerVlans = {
    MGMT  = { tag = 10; };
    INFRA = { tag = 11; };
    HOME  = { tag = 20; accessPorts = [ "lan1" ]; };
    DMZ   = { tag = 100; };
  };

  # VLANs matching actual deployed configuration
  # Mesh APs use 10xx tags on bat0 (bat0.1010, bat0.1020, etc.)
  meshVlans = {
    MGMT = { tag = 10; };
    HOME = { tag = 20; };
  };

  # Switch VLANs - arseille uses standard VLAN tags on a bridge
  # Trunk ports (lan1-4) carry all VLANs tagged; access ports are untagged
  switchVlans = {
    MGMT     = { tag = 10; accessPorts = [ "lan7" "lan8" ]; };
    INFRA    = { tag = 11; };
    HOME     = { tag = 20; accessPorts = [ "lan5" "lan6" ]; };
    GUEST    = { tag = 30; };
    ADU      = { tag = 31; };
    IOT      = { tag = 40; };
    GAME     = { tag = 41; };
    MEDIA    = { tag = 42; };
    DMZ      = { tag = 100; };
  };

  # SSH authorized keys for deployment
  authorizedKeys = [
    keys.ssh.deploy
    keys.ssh.home
  ];

  # Common AP networks (can be overridden per-device)
  # SSIDs and keys are configured via secrets post-deployment — only structural
  # config (network assignment, encryption type) lives here.
  defaultAPNetworks = {
    main = {
      network = "lan";
      encryption = "sae-mixed";
    };
    secondary = {
      network = "lan";
      encryption = "sae-mixed";
    };
  };
}
