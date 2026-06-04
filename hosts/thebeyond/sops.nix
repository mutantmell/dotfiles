{config, ...}: {
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/persist/var/lib/sops-nix/key.txt";
    secrets = {
      "wg-vpn-privatekey" = {
        mode = "0440";
        inherit (config.users.users."systemd-network") group;
      };
      "wg-media-privatekey" = {
        mode = "0440";
        inherit (config.users.users."systemd-network") group;
      };
      "dyndns-host-domain" = {};
      "dyndns-host-password" = {};
      "dyndns-host-name" = {};
    };
  };
}
