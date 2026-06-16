{config, ...}: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = {
      # Bootstrap mappings keep the flake buildable until the operator creates
      # the Forgejo OAuth app and rotates these to dedicated Woodpecker values.
      "woodpecker-agent-secret".key = "forgejo-runner-token";
      "woodpecker-forgejo-client".key = "forgejo-runner-token";
      "woodpecker-forgejo-secret".key = "forgejo-runner-token";
    };
    templates."woodpecker-server.env".content = ''
      WOODPECKER_AGENT_SECRET=${config.sops.placeholder."woodpecker-agent-secret"}
      WOODPECKER_FORGEJO_CLIENT=${config.sops.placeholder."woodpecker-forgejo-client"}
      WOODPECKER_FORGEJO_SECRET=${config.sops.placeholder."woodpecker-forgejo-secret"}
    '';
  };
}
