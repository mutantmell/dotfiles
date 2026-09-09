{
  pkgs,
  lib,
}: let
  frontend = import ../../hosts/calvard/microvm/guests/creil/modules/pages.nix {inherit pkgs;};
  forgejo = import ../../hosts/calvard/microvm/guests/creil/modules/forgejo.nix {
    inherit lib;
    config.services.forgejo.package = pkgs.forgejo;
  };
  evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      frontend
      ({lib, ...}: {
        options.environment.persistence = lib.mkOption {
          type = lib.types.attrs;
          default = {};
        };
        config = {
          nixpkgs.pkgs = pkgs;
          services.caddy.virtualHosts = forgejo.services.caddy.virtualHosts;
          system.stateVersion = "25.11";
        };
      })
    ];
  };
in
  pkgs.runCommand "git-pages-production-config" {nativeBuildInputs = [pkgs.caddy pkgs.python3];} ''
    caddy adapt --config ${evaluated.config.services.caddy.configFile} > config.json
    python - <<'PY'
    import json
    config = json.load(open("config.json"))
    automation = config["apps"]["tls"]["automation"]
    assert automation["on_demand"]["permission"]["endpoint"] == "http://127.0.0.1:3083"
    policies = automation["policies"]
    assert any(p.get("on_demand") for p in policies)
    for policy in policies:
        issuer, = policy["issuers"]
        assert issuer["module"] == "acme", issuer
        assert issuer["ca"] == "https://basel.internal/acme/acme/directory", issuer
        assert issuer["trusted_roots_pem_files"] == ["${pkgs.mmell.lib.data.pki.root}"], issuer
        assert issuer["challenges"]["tls-alpn"]["disabled"], issuer
    def walk(value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from walk(child)
        elif isinstance(value, list):
            for child in value:
                yield from walk(child)
    routes = list(walk(config["apps"]["http"]))
    caps = [r for r in routes if r.get("handler") == "request_body"]
    assert len(caps) == 2 and all(r["max_size"] == 512 * 1024 * 1024 for r in caps), caps
    assert sum(r.get("not") == [{"path": ["/v2/*"]}] for r in routes) == 2
    assert not any(r.get("request_buffers") or r.get("response_buffers") for r in routes)
    PY
    cp config.json $out
  ''
