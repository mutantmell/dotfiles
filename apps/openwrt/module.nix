{ lib, ... }:

{
  # terminology derived from: https://openwrt.org/docs/guide-user/base-system/uci#uci_dataobject_model
  options.uci.config = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf (lib.types.submodule {
      options.type = lib.mkOption {
        type = lib.types.str;
      };
      options.name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      options.options = lib.mkOption {
        type = lib.types.attrsOr (
          lib.types.either lib.types.str (lib.types.listOf lib.types.str)
        );
      };
    }));
    example = {
      example = [
        {
          type = "example";
          name = "test";
          options = {
            string = "some value";
            boolean = "1";
            collection = [ "first item" "second item" ];
          };
        }
      ];
      network = [
        {
          type = "interface";
          name = "lan";
          options = {
            ifname = "eth1";
            force_link = "1";
            type = "bridge";
            proto = "static";
            ipaddr = "192.168.1.1";
            netmask = "255.255.255.0";
            ip6assign = "60";
            delegate = "0";
          };
        }
        {
          type = "switch";
          options = {
            name = "switch0";
            reset = "1";
            enable_vlan = "1";
          };
        }
      ];
    };
    default = {};
  };
  # TODO: maybe also a direct sops file?
  options.uci.secretsFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = "A file containing secrets for the router configuration.";
  };

  
}
