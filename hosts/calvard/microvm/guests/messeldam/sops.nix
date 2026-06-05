{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = {
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
      # OIDC client secret *hash* — consumed only via the sops template below
      # (substituted by sops as root), so no owner is needed. Only confidential
      # clients need one; step-ca is a public client (no secret).
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
#   # Per-client secrets (confidential clients only) — generate ONE plaintext,
#   # hash it. The HASH goes here; the SAME PLAINTEXT goes in the consumer's sops
#   # (perses on tharbad: `perses-oidc-client-secret`). They MUST correspond — the
#   # consumer sends the plaintext and Authelia hashes it and compares. step-ca
#   # (basel, 2c) is a public client and needs no secret.
#   #
#   #   PT=$(openssl rand -hex 32); echo "plaintext: $PT"   # → tharbad sops
#   #   nix run nixpkgs#authelia -- crypto hash generate pbkdf2 \
#   #       --variant sha512 --no-confirm --password "$PT" | sed 's/^Digest: //'
#   #
#   # Store ONLY the digest, which begins with `$pbkdf2-sha512$…`. Do NOT include
#   # the `Digest: ` label the command prints, and no surrounding quotes/newline —
#   # a malformed hash makes Authelia reject every login with `invalid_client`
#   # (and logs a client-secret-format warning at authelia-main startup).
#   authelia-oidc-perses-secret-hash  : $pbkdf2-sha512$…(digest only)

