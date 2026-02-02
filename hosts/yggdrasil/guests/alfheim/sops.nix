{ config, ... }:

{
  # Sops configuration for alfheim microVM
  # Authentication is handled by Surtr's oauth2-proxy via nginx auth_request,
  # so no OAuth secrets are needed here. This file is kept for future secrets
  # (e.g., if Adguard Home needs any secret configuration).

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/static/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      # No secrets needed currently - auth handled by Surtr
    };
  };
}
