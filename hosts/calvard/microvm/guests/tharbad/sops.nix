_: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "perses-oidc-client-secret" = {};
      "perses-encryption-key" = {};
      "ntfy-admin-password" = {};
      # Tharbad's own observability token (used by its fluent-bit agent).
      "observability-token" = {};
      # Loki ingest auth: pre-bcrypt-hashed htpasswd file, one line per fleet host.
      # Format: hostname:$2y$05$<bcrypt-hash>
      "loki-htpasswd" = {
        owner = "nginx";
        group = "nginx";
        mode = "0440";
      };
      # Per-host bearer tokens for vmauth. Used to generate the vmauth auth.yml
      # via sops.templates. Plaintext only lives on tharbad; fleet hosts get only
      # their own token in their own sops file.
      "host-tokens/thebeyond" = {};
      "host-tokens/calvard" = {};
      "host-tokens/erebonia" = {};
      "host-tokens/liberl" = {};
      "host-tokens/tharbad" = {};
      "host-tokens/phantasma" = {};
      "host-tokens/basel" = {};
      "host-tokens/messeldam" = {};
      "host-tokens/langport" = {};
      "host-tokens/creil" = {};
      "host-tokens/oracion" = {};
      "host-tokens/zeiss" = {};
      "host-tokens/saint-arkh" = {};
      "host-tokens/trista" = {};
      "host-tokens/bose" = {};
      "host-tokens/edith" = {};
    };
  };
}
