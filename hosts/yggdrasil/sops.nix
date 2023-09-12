{ config, ... }:
{
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/root/.ssh/id_ed25519" ];
    secrets = {
      "chap-secrets" = {
        path = "/etc/ppp/chap-secrets";
      };
      "pppd-userfile" = {};
      "wg-vpn-privatekey" = {
        mode = "0440";
        group = config.users.users."systemd-network".group;
      };
      "wg-mx-privatekey" = {
        mode = "0440";
        group = config.users.users."systemd-network".group;
      };
      "wg-ba-privatekey" = {
        mode = "0440";
        group = config.users.users."systemd-network".group;
      };
      "dynamic-network-env.conf" = {};
      "dyndns-host-domain" = {};
      "dyndns-host-password" = {};
    };
  };
}
