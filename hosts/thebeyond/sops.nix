{config, ...}: {
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "wg-vpn-privatekey" = {
        mode = "0440";
        inherit (config.users.users."systemd-network") group;
      };
      "wg-ba-privatekey" = {
        mode = "0440";
        inherit (config.users.users."systemd-network") group;
      };
      "wg-media-privatekey" = {
        mode = "0440";
        inherit (config.users.users."systemd-network") group;
      };
      "dyndns-host-domain" = {};
      "dyndns-host-password" = {};
    };
  };
}
