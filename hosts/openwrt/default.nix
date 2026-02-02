# OpenWrt mesh AP configurations
#
# Each device is defined with its hardware profile, network settings,
# and mesh configuration. Images are built using nix-openwrt-imagebuilder.
#
# Build an image:
#   nix build .#openwrtImages.<device-name>
#
# Deploy to device:
#   nix run .#openwrt-deploy -- <device-name> <device-ip>
{ lib, pkgs, openwrt }:

let
  # Import common data
  data = import ../../lib/common/data;

  # Shared mesh configuration matching yggdrasil's batman-adv setup
  meshConfig = {
    meshId = "mmell-mesh";
    # meshKey should be provided via secrets, not committed
    # For initial setup, use null (open mesh) then configure via UCI
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
  defaultAPNetworks = {
    # Main network (HOME VLAN)
    main = {
      ssid = "MyNetwork";
      network = "vlan_HOME";
      encryption = "sae-mixed";
      # key should be provided via secrets
    };
    # Guest network
    guest = {
      ssid = "MyNetwork-Guest";
      network = "vlan_GUEST";
      encryption = "sae-mixed";
    };
    # IoT network (hidden)
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
