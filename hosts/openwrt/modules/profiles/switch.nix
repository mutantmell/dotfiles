{
  lib,
  config,
  openwrtLib,
  owrtData,
  ...
}: let
  cfg = config.openwrt;
in {
  options.openwrt.switch = {
    vlanId = lib.mkOption {
      type = lib.types.int;
      description = "VLAN used for the switch management address.";
    };
    vlans = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = owrtData.switchVlans;
    };
    trunkPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = owrtData.defaultSwitchTrunkPorts;
    };
    lanAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = owrtData.mkAddresses cfg.switch.vlanId cfg.device.hostId;
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = owrtData.mkGateway cfg.switch.vlanId;
    };
  };

  config.openwrt = {
    device.role = "switch";
    packages.base = openwrtLib.defaultSwitchPackages;
    uci.generatedConfig = openwrtLib.mkSwitchConfig {
      inherit (cfg) hostname authorizedKeys;
      inherit (cfg.locale) timezone;
      inherit (cfg.switch) lanAddresses gateway vlans trunkPorts;
    };
  };
}
