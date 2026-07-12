{
  lib,
  config,
  openwrtLib,
  owrtData,
  ...
}: let
  cfg = config.openwrt;
in {
  options.openwrt.simpleAP = {
    vlanId = lib.mkOption {
      type = lib.types.int;
      description = "VLAN used for the AP management/LAN address.";
    };
    lanAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = owrtData.mkAddresses cfg.simpleAP.vlanId cfg.device.hostId;
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = owrtData.mkGateway cfg.simpleAP.vlanId;
    };
    encryption = lib.mkOption {
      type = lib.types.str;
      default = owrtData.defaultEncryption;
    };
  };

  config.openwrt = {
    device.role = "simpleAP";
    packages.base = openwrtLib.defaultSimpleAPPackages;
    uci.generatedConfig = openwrtLib.mkSimpleAPConfig {
      inherit (cfg) hostname authorizedKeys;
      inherit (cfg.locale) country timezone;
      inherit (cfg.simpleAP) lanAddresses gateway encryption;
    };
  };
}
