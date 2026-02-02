# OpenWrt mesh AP configurations
#
# Each device is defined with its hardware profile, network settings,
# and mesh configuration. Images are built using nix-openwrt-imagebuilder.
#
# SECRETS: Wifi/mesh passwords are NOT included in images (would expose them
# in nix store). Instead, secrets are configured post-deployment via SSH.
# Create hosts/openwrt/secrets/wifi.yaml with: sops hosts/openwrt/secrets/wifi.yaml
#
# Build an image:
#   nix build .#openwrtImages.<device-name>
#
# Deploy to device (includes secrets configuration):
#   nix run .#openwrt-deploy -- <device-name> <device-ip>
#
# Configure secrets on existing device:
#   nix run .#openwrt-configure-secrets -- <device-ip>
{ lib, pkgs, openwrt }:

let
  # Import common data
  data = import ../../lib/common/data;

  # Shared mesh configuration matching yggdrasil's batman-adv setup
  # Note: meshKey is intentionally omitted - configured via secrets post-deployment
  meshConfig = {
    meshId = "mmell-mesh";
  };

  # VLANs matching yggdrasil's configuration
  vlans = {
    MGMT = { tag = 10; };
    HOME = { tag = 20; };
    GUEST = { tag = 30; };
    IOT = { tag = 40; };
    GAME = { tag = 41; };
  };

  # SSH authorized keys for deployment
  authorizedKeys = [
    data.keys.ssh.deploy
    data.keys.ssh.home
  ];

  # Common AP networks (can be overridden per-device)
  # Note: Keys are intentionally omitted - configured via secrets post-deployment
  # The deploy script matches networks by SSID pattern to apply keys
  defaultAPNetworks = {
    # Main network (HOME VLAN) - key set from wifi_keys.main
    main = {
      ssid = "MyNetwork";
      network = "vlan_HOME";
      encryption = "sae-mixed";
    };
    # Guest network - key set from wifi_keys.guest
    guest = {
      ssid = "MyNetwork-Guest";
      network = "vlan_GUEST";
      encryption = "sae-mixed";
    };
    # IoT network (hidden) - key set from wifi_keys.iot
    iot = {
      ssid = "MyNetwork-IoT";
      network = "vlan_IOT";
      encryption = "psk2";
      hidden = true;
    };
  };

  # Helper to create a mesh AP configuration
  mkMeshAP = { hostname, profile, lanAddress ? null, extraPackages ? [], extraConfig ? {} }:
    openwrt.mkMeshAPImage {
      inherit pkgs profile hostname lanAddress extraPackages extraConfig;
      inherit (meshConfig) meshId;
      inherit vlans authorizedKeys;
      apNetworks = defaultAPNetworks;
      timezone = "America/Los_Angeles";
    };

in {
  # =============================================================================
  # Device Definitions
  # =============================================================================
  # Add your OpenWrt mesh devices here. Each device needs:
  # - hostname: Device hostname (used in config and for identification)
  # - profile: OpenWrt device profile (run `nix run .#openwrt-profiles` to list)
  # - lanAddress: Optional static IP on management VLAN
  #
  # Find your device profile:
  #   nix run github:astro/nix-openwrt-imagebuilder -- list-profiles | grep -i <device>
  # =============================================================================

  # Example: Linksys WRT3200ACM mesh AP
  # fenrir = mkMeshAP {
  #   hostname = "fenrir";
  #   profile = "linksys_wrt3200acm";
  #   lanAddress = "10.0.10.10";
  # };

  # Example: TP-Link Archer C7 v5
  # sleipnir = mkMeshAP {
  #   hostname = "sleipnir";
  #   profile = "tplink_archer-c7-v5";
  #   lanAddress = "10.0.10.11";
  # };

  # Example: GL.iNet GL-AR750S (Slate)
  # hugin = mkMeshAP {
  #   hostname = "hugin";
  #   profile = "glinet_gl-ar750s-nor-nand";
  #   lanAddress = "10.0.10.12";
  # };

  # =============================================================================
  # Template: Uncomment and modify for your devices
  # =============================================================================

  # <device-name> = mkMeshAP {
  #   hostname = "<device-name>";
  #   profile = "<openwrt-profile>";
  #   lanAddress = "10.0.10.XX";  # Optional: static IP on MGMT VLAN
  #   extraPackages = [];          # Additional packages to install
  #   extraConfig = {};            # Override/extend UCI configuration
  # };
}
