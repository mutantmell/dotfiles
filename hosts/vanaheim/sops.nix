{ config, ... }:

# todo: encrypt stuff
{
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      "chap-secrets" = {
        path = "/etc/ppp/chap-secrets";
      };
      "pppd-userfile" = {};
    };
  };
}
