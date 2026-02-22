{ config, ... }:
{
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      "chap-secrets" = {
        path = "/etc/ppp/chap-secrets";
      };
      "pppd-userfile" = {};
      "wg-vpn-privatekey" = {
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
