# Exercise the real Pages service/frontend, with a local test issuer and a
# small Forgejo API fixture. Production ACME configuration is separately validated.
{
  pkgs,
  lib,
}: let
  runner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
  frontend = import ../../hosts/calvard/microvm/guests/creil/modules/pages.nix {inherit pkgs;};
  forgejo = import ../../hosts/calvard/microvm/guests/creil/modules/forgejo.nix {
    inherit lib;
    config.services.forgejo.package = pkgs.forgejo;
  };
  api = pkgs.writeText "forgejo-fixture.py" ''
    import json
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            token = self.headers.get("Authorization", "")
            if self.path == "/api/v1/user":
                result = {"id": 1, "login": "alice"}
            elif self.path.startswith("/api/v1/repos/"):
                result = {"permissions": {"push": token == "token writer" and self.path == "/api/v1/repos/alice/demo"}}
            else:
                result = {"host": self.headers.get("Host"), "scheme": self.headers.get("X-Forwarded-Proto")}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
    HTTPServer(("127.0.0.1", 3000), Handler).serve_forever()
  '';
in
  runner {
    name = "git-pages";
    containers.server = {lib, ...}: {
      imports = [
        frontend
        ../lib/test-minimal-base.nix
      ];
      # Persistence mounting is provided by the host's impermanence integration.
      options.environment.persistence = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
      config = {
        services.caddy.acmeCA = lib.mkForce null;
        services.caddy.globalConfig = lib.mkForce (lib.replaceStrings [
            "acme_ca_root ${pkgs.mmell.lib.data.pki.root}"
            "cert_issuer acme {\n  disable_tlsalpn_challenge\n}"
          ] ["" "cert_issuer internal"]
          (frontend.services.caddy.globalConfig + "\nlog {\n" + frontend.services.caddy.logFormat + "\n}\n"));
        services.caddy.virtualHosts = forgejo.services.caddy.virtualHosts;
        networking.extraHosts = "127.0.0.1 pages.internal forgejo.internal creil.internal alice.pages.internal missing.pages.internal";
        environment.systemPackages = [pkgs.curl pkgs.gnutar pkgs.python3];
        systemd.services.forgejo-fixture = {
          wantedBy = ["multi-user.target"];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${api}";
        };
      };
    };
    testScript = ''
      start_all()
      server.wait_for_unit("git-pages.service")
      server.wait_for_unit("caddy.service")
      server.wait_for_unit("forgejo-fixture.service")
      server.wait_until_succeeds("test -s /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt")
      server.succeed("cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt > /tmp/ca.crt")
      # Also trust the fixture's HTTPS Forgejo certificate in git-pages itself.
      server.succeed("cp /tmp/ca.crt /tmp/ca-bundle.crt; mount --bind /tmp/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; systemctl restart git-pages")
      server.wait_for_open_port(3081)
      server.wait_until_succeeds("curl --cacert /tmp/ca.crt -fsS https://forgejo.internal | grep -q 'https'")
      server.succeed("mkdir /tmp/site; echo first > /tmp/site/index.html; tar -C /tmp/site -cf /tmp/site.tar .")
      upload = "curl --cacert /tmp/ca.crt -sS -o /tmp/response -w '%{http_code}' -X PUT https://pages.internal/demo/ -H 'Host: alice.pages.internal' -H 'Content-Type: application/x-tar' --data-binary @/tmp/site.tar"
      # Bootstrap uses apex SNI with the user Host, before on-demand TLS is allowed.
      status = server.succeed("curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:3083/?domain=alice.pages.internal'")
      assert status == "404", status
      for token in ["reader", "wrong"]:
          assert server.succeed(upload + f" -H 'Forge-Authorization: token {token}'") == "401"
      assert server.succeed(upload) == "401"
      status = server.succeed(upload + " -H 'Forge-Authorization: token writer'")
      assert status in ["200", "201", "204"], server.succeed("cat /tmp/response")
      server.succeed("curl --cacert /tmp/ca.crt -fsSI https://alice.pages.internal/demo/ | grep -i 'server:.*git-pages'")
      assert server.succeed(upload + " -H 'Forge-Authorization: token reader'") == "401"
      server.succeed("curl --cacert /tmp/ca.crt -fsS https://alice.pages.internal/demo/ | grep -qx first")
      assert server.succeed("curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:3083/?domain=alice.pages.internal'") == "200"
      for domain in ["forgejo.internal", "evil.example", "nested.alice.pages.internal"]:
          assert server.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' 'http://127.0.0.1:3083/?domain={domain}'") == "403"
      server.fail("curl --cacert /tmp/ca.crt -fsS https://missing.pages.internal/demo/")
      server.succeed("echo second > /tmp/site/index.html; tar -C /tmp/site -cf /tmp/site.tar .")
      assert server.succeed(upload + " -H 'Forge-Authorization: token writer'") in ["200", "201", "204"]
      # Fail a request through each hostname: custom publishing tokens must
      # never appear in access/error logs (standard Authorization stays redacted).
      server.succeed("systemctl stop forgejo-fixture git-pages")
      for host in ["pages.internal", "forgejo.internal", "creil.internal", "alice.pages.internal"]:
          server.succeed(f"curl --cacert /tmp/ca.crt -sS -o /dev/null -X PUT https://{host}/log-redaction-probe -H 'Forge-Authorization: token sentinel-forge-secret' -H 'Authorization: token sentinel-standard-secret'")
      server.succeed("journalctl --sync")
      logs = server.succeed("journalctl -u caddy -u git-pages --no-pager")
      assert "log-redaction-probe" in logs
      assert "sentinel-forge-secret" not in logs
      assert "sentinel-standard-secret" not in logs
      server.succeed("systemctl restart git-pages caddy")
      server.wait_until_succeeds("curl --cacert /tmp/ca.crt -fsS https://alice.pages.internal/demo/ | grep -qx second")
    '';
  }
