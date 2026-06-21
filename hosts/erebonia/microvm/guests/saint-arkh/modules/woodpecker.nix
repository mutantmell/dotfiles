{
  config,
  lib,
  pkgs,
  ...
}: let
  configServicePort = 9001;
  configService = pkgs.writers.writePython3 "woodpecker-flake-config-service" {} ''
    import json
    import textwrap
    from http.server import BaseHTTPRequestHandler, HTTPServer

    PIPELINE = textwrap.dedent("""\
    when:
      - event: [push, pull_request, manual]

    clone:
      - name: git
        image: docker.io/woodpeckerci/plugin-git:2.9.1
        settings:
          depth: 0
        backend_options:
          kubernetes:
            runtimeClassName: runsc
            serviceAccountName: woodpecker-build-step
            securityContext:
              runAsNonRoot: true
              runAsUser: 1000
              runAsGroup: 1000
              fsGroup: 1000
              seccompProfile:
                type: RuntimeDefault
              allowPrivilegeEscalation: false
              capabilities:
                drop: [ALL]

    steps:
      - name: agent-preflight-quick
        image: localhost/dotfiles-ci-nix:0.1.0
        commands:
          - >
            nix --extra-experimental-features 'nix-command flakes'
            develop --command ./scripts/agent-preflight.sh --quick
        backend_options:
          kubernetes:
            runtimeClassName: runsc
            serviceAccountName: woodpecker-build-step
            securityContext:
              runAsNonRoot: true
              runAsUser: 1000
              runAsGroup: 1000
              fsGroup: 1000
              seccompProfile:
                type: RuntimeDefault
              allowPrivilegeEscalation: false
              capabilities:
                drop: [ALL]
    """)


    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/healthz":
                self.send_error(404)
                return
            self.send_response(204)
            self.end_headers()

        def do_POST(self):
            length = int(self.headers.get("content-length", "0"))
            if length:
                self.rfile.read(length)
            body = json.dumps({
                "configs": [
                    {
                        "name": "flake-generated.yml",
                        "data": PIPELINE,
                    }
                ]
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            return


    HTTPServer(
        ("127.0.0.1", ${toString configServicePort}),
        Handler,
    ).serve_forever()
  '';
in {
  services.woodpecker-server = {
    enable = true;
    environment = {
      WOODPECKER_HOST = "https://woodpecker.internal";
      WOODPECKER_SERVER_ADDR = "127.0.0.1:8000";
      WOODPECKER_GRPC_ADDR = ":9000";
      WOODPECKER_ADMIN = "mutantmell";
      WOODPECKER_OPEN = "true";
      WOODPECKER_REPO_OWNERS = "mutantmell";
      WOODPECKER_FORGEJO = "true";
      WOODPECKER_FORGEJO_URL = "https://forgejo.internal";
      WOODPECKER_DEFAULT_CLONE_PLUGIN = "docker.io/woodpeckerci/plugin-git:2.9.1";
      WOODPECKER_PLUGINS_TRUSTED_CLONE = "docker.io/woodpeckerci/plugin-git:2.9.1";
      WOODPECKER_CONFIG_EXTENSION_ENDPOINT = "http://127.0.0.1:${toString configServicePort}";
      WOODPECKER_CONFIG_EXTENSION_EXCLUSIVE = "true";
      WOODPECKER_CONFIG_EXTENSION_NETRC = "false";
      WOODPECKER_EXTENSIONS_ALLOWED_HOSTS = "loopback";
    };
    environmentFile = [config.sops.templates."woodpecker-server.env".path];
  };

  systemd.services.woodpecker-server = {
    after = ["woodpecker-flake-config.service"];
    requires = ["woodpecker-flake-config.service"];
  };

  systemd.services.woodpecker-flake-config = {
    description = "Woodpecker flake-backed configuration extension";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = configService;
      Restart = "on-failure";
      RestartSec = 15;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    virtualHosts."woodpecker.internal" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8000";
        proxyWebsockets = true;
      };
    };
  };
}
