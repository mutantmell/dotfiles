{
  config,
  lib,
  pkgs,
  ...
}: let
  configServicePort = 9001;
  configService = pkgs.writers.writePython3 "woodpecker-flake-config-service" {} ''
    import json
    import os
    import re
    import shutil
    import subprocess
    import tempfile
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    CHECK_SYSTEM = "x86_64-linux"
    CHECK_SHARD_SIZE = 2
    GIT = "${pkgs.git}/bin/git"
    NIX = "${config.nix.package}/bin/nix"
    REPO_NAME = "dotfiles"
    DOTFILES_CLONE_URL = "https://forgejo.internal/mutantmell/dotfiles.git"
    SAFE_CHECK_RE = re.compile(r"^host-eval-[A-Za-z0-9_-]+$")

    PIPELINE_HEADER = """\
    when:
      - event: [push, pull_request, manual]

    clone:
      - name: git
        image: localhost/woodpecker-plugin-git:2.9.1-internal-ca
        settings:
          depth: 0
          home: /tmp
        backend_options:
          kubernetes:
            runtimeClassName: runsc
            resources:
              requests:
                cpu: 50m
                memory: 64Mi
              limits:
                cpu: 250m
                memory: 256Mi
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
        image: localhost/dotfiles-ci-nix:0.1.3
        commands:
          - |
            if ionice -c 3 true 2>/dev/null; then
              ionice -c 3 nice -n 10 \\
                nix --extra-experimental-features 'nix-command flakes' \\
                develop --command ./scripts/agent-preflight.sh --quick
            else
              nice -n 10 \\
                nix --extra-experimental-features 'nix-command flakes' \\
                develop --command ./scripts/agent-preflight.sh --quick
            fi
        backend_options:
          kubernetes:
            runtimeClassName: runsc
            resources:
              requests:
                cpu: 500m
                memory: 2Gi
              limits:
                cpu: "2"
                memory: 8Gi
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
    """

    HOST_EVAL_STEP_TEMPLATE = """\
      - name: {step_name}
        image: localhost/dotfiles-ci-nix:0.1.3
        commands:
          - |
            if ionice -c 3 true 2>/dev/null; then
              ionice -c 3 nice -n 10 \\
                nix --extra-experimental-features 'nix-command flakes' \\
                develop --command ./scripts/run-checks.sh \\
                  {checks}
            else
              nice -n 10 \\
                nix --extra-experimental-features 'nix-command flakes' \\
                develop --command ./scripts/run-checks.sh \\
                  {checks}
            fi
        backend_options:
          kubernetes:
            runtimeClassName: runsc
            resources:
              requests:
                cpu: 750m
                memory: 2Gi
              limits:
                cpu: "2"
                memory: 6Gi
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
    """


    def run(cmd, cwd):
        env = os.environ.copy()
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["HOME"] = tempfile.mkdtemp(prefix="woodpecker-home-")
        try:
            return subprocess.run(
                cmd,
                cwd=cwd,
                env=env,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=180,
            )
        finally:
            shutil.rmtree(env["HOME"], ignore_errors=True)


    def checkout_payload_repo(payload):
        repo = payload.get("repo", {})
        pipeline = payload.get("pipeline", {})
        if not is_dotfiles_repo(repo):
            return None

        clone_url = (
            pipeline.get("clone_url")
            or repo.get("clone_url")
            or repo.get("git_http_url")
            or repo.get("link_url")
            or repo.get("link")
            or DOTFILES_CLONE_URL
        )
        if not clone_url:
            return None

        checkout = tempfile.mkdtemp(prefix="woodpecker-config-repo-")
        try:
            clone_cmd = [
                GIT,
                "clone",
                "--quiet",
                "--filter=blob:none",
                clone_url,
                checkout,
            ]
            run(clone_cmd, None)
            commit = (
                pipeline.get("commit")
                or pipeline.get("after")
                or pipeline.get("sha")
            )
            refspec = pipeline.get("refspec")
            ref = pipeline.get("ref")
            if refspec:
                run([GIT, "fetch", "--quiet", "origin", refspec], checkout)
            elif ref and not ref.startswith("refs/heads/"):
                run([GIT, "fetch", "--quiet", "origin", ref], checkout)
            if commit:
                run([GIT, "checkout", "--quiet", commit], checkout)
            return checkout
        except Exception:
            shutil.rmtree(checkout, ignore_errors=True)
            return None


    def is_dotfiles_repo(repo):
        repo_name = repo.get("name")
        repo_slug = repo.get("slug", "")
        return repo_name == REPO_NAME or repo_slug.endswith(f"/{REPO_NAME}")


    def repo_path_for_payload(payload):
        cwd = os.getcwd()
        if os.path.exists(os.path.join(cwd, "flake.nix")):
            return cwd, False

        checkout = checkout_payload_repo(payload)
        if checkout:
            return checkout, True

        return None, False


    def discover_safe_checks(repo_path):
        if not repo_path:
            return []

        attr = f".#checks.{CHECK_SYSTEM}"
        result = run(
            [
                NIX,
                "--extra-experimental-features",
                "nix-command flakes",
                "eval",
                attr,
                "--apply",
                "x: builtins.attrNames x",
                "--json",
            ],
            repo_path,
        )
        checks = json.loads(result.stdout)
        return sorted(
            check
            for check in checks
            if SAFE_CHECK_RE.fullmatch(check)
        )


    def chunked(items, size):
        for index in range(0, len(items), size):
            yield items[index:index + size]


    def render_host_eval_steps(checks):
        rendered = []
        for index, shard in enumerate(chunked(checks, CHECK_SHARD_SIZE), start=1):
            rendered.append(
                HOST_EVAL_STEP_TEMPLATE.format(
                    step_name=f"host-eval-shard-{index}",
                    checks=" ".join(shard),
                )
            )
        return "".join(rendered)


    def render_pipeline(payload):
        cleanup = False
        try:
            repo_path, cleanup = repo_path_for_payload(payload)
            try:
                checks = discover_safe_checks(repo_path)
            finally:
                if cleanup:
                    shutil.rmtree(repo_path, ignore_errors=True)
        except Exception as err:
            print(f"host-eval discovery failed: {err}", flush=True)
            checks = []

        return PIPELINE_HEADER + render_host_eval_steps(checks)


    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/healthz":
                self.send_error(404)
                return
            self.send_response(204)
            self.end_headers()

        def do_POST(self):
            length = int(self.headers.get("content-length", "0"))
            payload = {}
            if length:
                try:
                    payload = json.loads(self.rfile.read(length))
                except json.JSONDecodeError as err:
                    self.send_error(400, f"invalid JSON payload: {err}")
                    return
            data = render_pipeline(payload)
            body = json.dumps({
                "configs": [
                    {
                        "name": "flake-generated.yml",
                        "data": data,
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


    ThreadingHTTPServer(
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
      WOODPECKER_DEFAULT_CLONE_PLUGIN = "localhost/woodpecker-plugin-git:2.9.1-internal-ca";
      WOODPECKER_PLUGINS_TRUSTED_CLONE = "localhost/woodpecker-plugin-git:2.9.1-internal-ca";
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
