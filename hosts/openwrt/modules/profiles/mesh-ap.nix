{
  lib,
  config,
  openwrtLib,
  owrtData,
  ...
}: let
  cfg = config.openwrt;
in {
  options.openwrt.mesh = {
    vlans = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = owrtData.meshVlans;
    };
    apNetworks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = owrtData.defaultAPNetworks;
    };
    lanAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = owrtData.mkAddresses cfg.mesh.vlans.HOME.tag cfg.device.hostId;
    };
    mgmtAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = owrtData.mkAddresses cfg.mesh.vlans.MGMT.tag cfg.device.hostId;
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = owrtData.mkGateway cfg.mesh.vlans.HOME.tag;
    };
    heBssColor = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
    };
    legacyRates = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config.openwrt = {
    device.role = "meshAP";
    packages.base = openwrtLib.defaultMeshPackages;
    uci.generatedConfig = openwrtLib.mkMeshAPConfig {
      inherit (cfg) hostname authorizedKeys;
      inherit (cfg.locale) country timezone;
      inherit (cfg.mesh) vlans apNetworks lanAddresses mgmtAddresses gateway heBssColor legacyRates;
    };
  };
}
