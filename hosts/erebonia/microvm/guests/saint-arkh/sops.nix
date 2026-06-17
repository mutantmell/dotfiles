{config, ...}: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = {
      "woodpecker-agent-secret" = {};
      "woodpecker-forgejo-client" = {};
      "woodpecker-forgejo-secret" = {};
    };
    templates."woodpecker-server.env".content = ''
      WOODPECKER_AGENT_SECRET=${config.sops.placeholder."woodpecker-agent-secret"}
      WOODPECKER_FORGEJO_CLIENT=${config.sops.placeholder."woodpecker-forgejo-client"}
      WOODPECKER_FORGEJO_SECRET=${config.sops.placeholder."woodpecker-forgejo-secret"}
    '';
  };
}
