{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = {
      "keycloak_password_file" = {};
      "keycloak_admin_password" = {};

      # --- Authelia ---
      # Read directly by the authelia-main system user.
      "authelia-jwt-secret".owner = "authelia-main";
      "authelia-storage-encryption-key".owner = "authelia-main";
      "authelia-oidc-hmac-secret".owner = "authelia-main";
      "authelia-oidc-issuer-private-key".owner = "authelia-main";
      "authelia-ldap-bind-password".owner = "authelia-main";
      # Jellyfin's LDAP bind password. Only consumed on messeldam to seed the
      # `jellyfin` bind user (via lldap-bootstrap's LoadCredential, read as root
      # by PID1 — no owner needed). The same value must be pasted into oracion's
      # sops for the Jellyfin LDAP plugin in Phase 2d.
      "jellyfin-ldap-bind-password" = {};
      # OIDC client secret *hashes* — consumed only via the sops template below
      # (substituted by sops as root), so no owner is needed.
      "authelia-oidc-step-ca-secret-hash" = {};
      "authelia-oidc-perses-secret-hash" = {};

      # --- lldap ---
      # Loaded via systemd LoadCredential (lldap is a DynamicUser).
      "lldap-admin-password" = {};
    };
  };
}
# Generating the new secret values (operator runs these, then `sops edit
# hosts/calvard/microvm/guests/messeldam/secrets/secrets.yaml` to paste them in):
#
#   # high-entropy random values
#   authelia-jwt-secret             : openssl rand -hex 48
#   authelia-storage-encryption-key : openssl rand -hex 48
#   authelia-oidc-hmac-secret       : openssl rand -hex 48
#   lldap-admin-password            : openssl rand -base64 24
#   authelia-ldap-bind-password     : openssl rand -base64 24
#   jellyfin-ldap-bind-password     : openssl rand -base64 24
#       (paste the same value into oracion's sops for the Jellyfin LDAP plugin)
#
#   # OIDC token-signing key (RSA 4096 PEM) — paste the whole PEM block
#   authelia-oidc-issuer-private-key: openssl genrsa 4096
#
#   # Per-client secrets — generate a plaintext, hash it. Store the HASH here;
#   # keep the PLAINTEXT for the consumer (perses on tharbad in 2a, step-ca on
#   # basel in 2c). Repeat once per client:
#   PT=$(openssl rand -hex 32); echo "plaintext: $PT"
#   nix run nixpkgs#authelia -- crypto hash generate pbkdf2 --variant sha512 --password "$PT"
#   authelia-oidc-step-ca-secret-hash : <Digest line from the hash output>
#   authelia-oidc-perses-secret-hash  : <Digest line from the hash output>

