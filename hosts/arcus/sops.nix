{config, ...}: {
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    # NOTE: If this fails, it's because the key hasn't been pushed yet.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    secrets = {
      "wg-media-privatekey" = {};
    };
  };
}
