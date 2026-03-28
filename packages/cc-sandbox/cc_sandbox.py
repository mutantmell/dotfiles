#!/usr/bin/env python3
"""cc-sandbox: Claude Code sandbox orchestrator.

Daemon + CLI for creating isolated Claude Code coding environments via deployd.

The daemon holds limited credentials (Keycloak, Forgejo) and manages sandbox
lifecycle — create, teardown, list. It never builds images or runs nix/skopeo.

The CLI has two roles:
  1. Thin client for daemon commands (create, teardown, list, ssh)
  2. Privileged image management (rebuild-image) — runs as the calling user,
     which has nix and skopeo access. Sends the digest to the daemon via
     the Unix socket (the daemon is the sole writer of state).

Security notes:
  - The daemon should not have nix, skopeo, or openssh in its PATH.
  - Container name injection: the daemon prefixes all names with "cc-" and
    deployd-helper validates names. For multi-user scenarios, add per-user
    namespacing or authentication on the Unix socket.
  - SSH host key verification: cc-sandbox ssh uses StrictHostKeyChecking=no
    because containers generate ephemeral host keys on boot. A proper fix
    is to have containers request SSH host certificates from step-ca, which
    requires br-deploy egress to the CA. Deferred to Phase D5.
"""

import argparse
import fcntl
import json
import os
import random
import socket
import socketserver
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

import requests

# --- Trails-themed hostname word lists ---
# Drawn from craft/arts naming in the Trails series.
ADJECTIVES = [
    "silver", "heavy", "phantom", "crimson", "azure", "steel", "raging",
    "golden", "shadow", "radiant", "iron", "mystic", "scarlet", "cobalt",
    "silent", "bright", "dark", "swift", "wild", "pale", "fierce", "hollow",
    "eternal", "frozen", "burning", "sacred", "fallen", "shining", "ancient",
    "tempest",
]

NOUNS = [
    "blade", "streak", "fang", "wing", "storm", "cross", "lance", "edge",
    "bolt", "spark", "crest", "howl", "thorn", "flame", "gale", "slash",
    "veil", "arrow", "tide", "blaze", "aegis", "shard", "talon", "wrath",
    "surge", "breaker", "dawn", "dusk", "oracle", "hammer",
]


def generate_hostname(existing_names):
    """Generate a random Trails-themed hostname not in existing_names."""
    attempts = 0
    while attempts < 1000:
        name = f"{random.choice(ADJECTIVES)}-{random.choice(NOUNS)}"
        if name not in existing_names:
            return name
        attempts += 1
    raise RuntimeError("failed to generate unique hostname after 1000 attempts")


# --- Configuration ---

class DaemonConfig:
    """Daemon configuration from environment variables.

    The daemon only needs HTTP client capabilities (Keycloak + deployd-api)
    and file access (state + secrets). It does NOT need nix, skopeo, or SSH.
    """

    def __init__(self):
        self.socket_path = os.environ.get(
            "CC_SANDBOX_SOCKET_PATH", "/run/cc-sandbox/cc-sandbox.sock"
        )
        self.state_file = os.environ.get(
            "CC_SANDBOX_STATE_FILE", "/var/lib/cc-sandbox/state.json"
        )
        self.auth_url = os.environ["CC_SANDBOX_AUTH_URL"]
        self.api_url = os.environ["CC_SANDBOX_API_URL"]
        self.registry = os.environ["CC_SANDBOX_REGISTRY"]
        # Forgejo API URL for repo operations (fork, etc.). Defaults to
        # https://<registry> since Forgejo serves both the container registry
        # and the git API, but can be overridden if they diverge.
        self.forgejo_url = os.environ.get(
            "CC_SANDBOX_FORGEJO_URL", f"https://{self.registry}"
        )
        self.image_name = os.environ.get("CC_SANDBOX_IMAGE_NAME", "deployd/claude-sandbox")
        self.ca_cert = os.environ.get("CC_SANDBOX_CA_CERT", "")
        self.dns_servers = os.environ.get("CC_SANDBOX_DNS_SERVERS", "")

        # OIDC client credentials (confidential client, not password grant)
        self.client_id = os.environ.get("CC_SANDBOX_CLIENT_ID", "cc-sandbox")
        self.client_secret = _read_secret("CC_SANDBOX_CLIENT_SECRET_FILE")
        self.forgejo_token = _read_secret("CC_SANDBOX_FORGEJO_TOKEN_FILE")

        # Token cache
        self._token = None
        self._token_expiry = 0

    def requests_verify(self):
        """Return the verify parameter for requests calls."""
        return self.ca_cert if self.ca_cert else True


def _read_secret(env_var):
    """Read a secret from a file path specified by an environment variable."""
    path = os.environ.get(env_var, "")
    if not path:
        return ""
    return Path(path).read_text().strip()


# --- State management ---

class State:
    """JSON state file with file locking."""

    def __init__(self, path):
        self.path = Path(path)

    def load(self):
        if not self.path.exists():
            return {"sandboxes": {}, "image_digest": ""}
        with open(self.path) as f:
            fcntl.flock(f, fcntl.LOCK_SH)
            try:
                return json.load(f)
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)

    def save(self, data):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.path, "w") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                json.dump(data, f, indent=2)
                f.write("\n")
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)


# --- Keycloak token management ---

def get_token(config):
    """Get a Keycloak access token, using cache if not expired."""
    now = time.time()
    if config._token and now < config._token_expiry - 30:
        return config._token

    resp = requests.post(
        config.auth_url,
        data={
            "grant_type": "client_credentials",
            "client_id": config.client_id,
            "client_secret": config.client_secret,
        },
        verify=config.requests_verify(),
    )
    resp.raise_for_status()
    body = resp.json()
    config._token = body["access_token"]
    config._token_expiry = now + body.get("expires_in", 300)
    return config._token


# --- deployd API client ---

def deployd_deploy(config, name, image, env=None):
    """Deploy a container via deployd-api. Returns the container IP."""
    token = get_token(config)
    payload = {"name": name, "image": image}
    if env:
        payload["env"] = env
    resp = requests.post(
        f"{config.api_url}/deploy",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json=payload,
        verify=config.requests_verify(),
    )
    resp.raise_for_status()
    body = resp.json()
    ip = None
    if "data" in body and body["data"]:
        ip = body["data"].get("ip")
    return ip


def deployd_inspect(config, name):
    """Inspect a container via deployd-api. Returns the IP if available."""
    token = get_token(config)
    resp = requests.get(
        f"{config.api_url}/inspect/{name}",
        headers={"Authorization": f"Bearer {token}"},
        verify=config.requests_verify(),
    )
    resp.raise_for_status()
    body = resp.json()
    if "data" in body and body["data"]:
        return body["data"].get("ip")
    return None


def deployd_teardown(config, name):
    """Tear down a container via deployd-api."""
    token = get_token(config)
    resp = requests.delete(
        f"{config.api_url}/teardown/{name}",
        headers={"Authorization": f"Bearer {token}"},
        verify=config.requests_verify(),
    )
    resp.raise_for_status()
    return resp.json()


# --- Image management (CLI-only, not used by daemon) ---

def rebuild_image(socket_path, registry, image_name, registry_user, forgejo_token,
                  ca_cert, flake_path, flake_attr):
    """Build, push, and record the sandbox image digest.

    Runs as the calling user (not the daemon) — requires nix and skopeo in PATH.
    Sends the digest to the daemon via the Unix socket so the daemon can record it.
    """
    # Build
    result = subprocess.run(
        ["nix", "build", f"{flake_path}#{flake_attr}",
         "--print-out-paths", "--no-link"],
        capture_output=True, text=True, check=True,
    )
    image_path = result.stdout.strip()

    # Push (with TLS verification via CA cert)
    dest = f"docker://{registry}/{image_name}:latest"
    skopeo_push = [
        "skopeo", "copy", "--insecure-policy",
        "--dest-creds", f"{registry_user}:{forgejo_token}",
        f"docker-archive:{image_path}", dest,
    ]
    if ca_cert:
        skopeo_push += ["--dest-cert-dir", str(Path(ca_cert).parent)]
    else:
        skopeo_push += ["--dest-tls-verify=false"]
    subprocess.run(skopeo_push, check=True)

    # Get digest (with TLS verification via CA cert)
    skopeo_inspect = [
        "skopeo", "inspect", "--insecure-policy",
        f"docker://{registry}/{image_name}:latest",
    ]
    if ca_cert:
        skopeo_inspect += ["--cert-dir", str(Path(ca_cert).parent)]
    else:
        skopeo_inspect += ["--tls-verify=false"]
    result = subprocess.run(skopeo_inspect, capture_output=True, text=True, check=True)
    digest = json.loads(result.stdout)["Digest"]

    # Send digest to daemon
    resp = send_command(socket_path, {"command": "set-digest", "digest": digest})
    if not resp.get("success"):
        raise RuntimeError(f"failed to set digest: {resp.get('message', 'unknown error')}")

    return digest


# --- Forgejo API client ---

def forgejo_fork(config, owner, repo):
    """Fork a repo under the 'cc' user on Forgejo. Returns the clone URL."""
    resp = requests.post(
        f"{config.forgejo_url}/api/v1/repos/{owner}/{repo}/forks",
        headers={"Authorization": f"token {config.forgejo_token}"},
        json={"organization": "cc"},
        verify=config.requests_verify(),
    )
    if resp.status_code in (409, 422):
        # Fork already exists (Forgejo returns 409 or 422 depending on version)
        return f"{config.forgejo_url}/cc/{repo}.git"
    resp.raise_for_status()
    return resp.json().get("clone_url", f"{config.forgejo_url}/cc/{repo}.git")


def parse_repo_url(url):
    """Parse a repo URL or shorthand into (owner, repo) tuple."""
    # Handle shorthand: owner/repo
    if "/" in url and "://" not in url and not url.startswith("git@"):
        parts = url.strip("/").split("/")
        if len(parts) == 2:
            return parts[0], parts[1].removesuffix(".git")

    # Handle full URL: https://host/owner/repo[.git]
    parsed = urlparse(url)
    parts = parsed.path.strip("/").split("/")
    if len(parts) >= 2:
        return parts[0], parts[1].removesuffix(".git")

    raise ValueError(f"cannot parse repo URL: {url}")


# --- Daemon command handlers ---

def handle_create(config, state, params):
    """Handle a create sandbox request."""
    data = state.load()

    # Check that an image digest exists (set by `cc-sandbox rebuild-image`)
    digest = data.get("image_digest", "")
    if not digest:
        return {
            "success": False,
            "message": "no image digest available — run 'cc-sandbox rebuild-image' first",
        }

    name = generate_hostname(set(data["sandboxes"].keys()))
    container_name = f"cc-{name}"
    image_ref = f"{config.registry}/{config.image_name}@{digest}"

    # Fork repo on Forgejo if specified (before deploy, so we have the URL)
    repo_param = params.get("repo", "")
    fork_url = ""
    env = {}
    if config.dns_servers:
        env["SANDBOX_DNS"] = config.dns_servers
    if repo_param:
        owner, repo_name = parse_repo_url(repo_param)
        fork_url = forgejo_fork(config, owner, repo_name)
        # Embed Forgejo token in the clone URL for non-interactive auth.
        # The fork is under the "cc" org whose token the daemon holds.
        parsed = urlparse(fork_url)
        authed_url = parsed._replace(
            netloc=f"cc:{config.forgejo_token}@{parsed.hostname}"
            + (f":{parsed.port}" if parsed.port else "")
        ).geturl()
        env["SANDBOX_REPO_URL"] = authed_url

    # Deploy via deployd-api (env vars are passed to container)
    deployd_deploy(config, container_name, image_ref, env=env or None)

    # Save state (IP resolved lazily via inspect when needed)
    data["sandboxes"][name] = {
        "container_name": container_name,
        "repo": fork_url,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    state.save(data)

    return {"success": True, "data": {"name": name}}


def handle_teardown(config, state, params):
    """Handle a teardown sandbox request."""
    name = params["name"]
    data = state.load()

    if name not in data["sandboxes"]:
        return {"success": False, "message": f"sandbox '{name}' not found"}

    container_name = data["sandboxes"][name]["container_name"]

    try:
        deployd_teardown(config, container_name)
    except Exception as e:
        return {"success": False, "message": f"teardown failed: {e}"}

    del data["sandboxes"][name]
    state.save(data)

    return {"success": True, "message": f"sandbox '{name}' torn down"}


def handle_list(state):
    """Handle a list sandboxes request."""
    data = state.load()
    sandboxes = []
    for name, info in data["sandboxes"].items():
        sandboxes.append({
            "name": name,
            "ip": info.get("ip", ""),
            "repo": info.get("repo", ""),
            "created_at": info.get("created_at", ""),
        })
    return {"success": True, "data": {"sandboxes": sandboxes}}


def handle_info(state, params):
    """Handle an info request for a single sandbox."""
    name = params["name"]
    data = state.load()

    if name not in data["sandboxes"]:
        return {"success": False, "message": f"sandbox '{name}' not found"}

    info = data["sandboxes"][name]
    return {
        "success": True,
        "data": {
            "name": name,
            "ip": info.get("ip", ""),
            "repo": info.get("repo", ""),
            "created_at": info.get("created_at", ""),
        },
    }


def handle_resolve_ip(config, state, params):
    """Resolve a sandbox's IP via deployd inspect, polling until available."""
    name = params["name"]
    timeout = params.get("timeout", 30)
    data = state.load()

    if name not in data["sandboxes"]:
        return {"success": False, "message": f"sandbox '{name}' not found"}

    # Return cached IP if we already have one
    cached_ip = data["sandboxes"][name].get("ip", "")
    if cached_ip:
        return {"success": True, "data": {"name": name, "ip": cached_ip}}

    container_name = data["sandboxes"][name]["container_name"]

    # Poll deployd-api for the IP
    deadline = time.time() + timeout
    ip = None
    while time.time() < deadline:
        try:
            ip = deployd_inspect(config, container_name)
        except Exception:
            pass
        if ip:
            break
        time.sleep(1)

    if not ip:
        return {"success": False, "message": f"sandbox '{name}' IP not available after {timeout}s"}

    # Cache the IP in state
    data = state.load()
    if name in data["sandboxes"]:
        data["sandboxes"][name]["ip"] = ip
        state.save(data)

    return {"success": True, "data": {"name": name, "ip": ip}}


def handle_set_digest(state, params):
    """Handle a set-digest request from the CLI after image push."""
    digest = params.get("digest", "")
    if not digest:
        return {"success": False, "message": "missing 'digest' parameter"}

    data = state.load()
    data["image_digest"] = digest
    state.save(data)

    return {"success": True, "message": f"digest set to {digest}"}


# --- Daemon ---

class DaemonHandler(socketserver.StreamRequestHandler):
    """Handle a single client connection on the Unix socket."""

    def handle(self):
        try:
            line = self.rfile.readline(1024 * 1024)  # 1 MiB limit
            if not line:
                return
            req = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            self._respond({"success": False, "message": f"invalid request: {e}"})
            return

        command = req.get("command", "")
        config = self.server.config
        state = self.server.state

        try:
            if command == "create":
                result = handle_create(config, state, req)
            elif command == "teardown":
                result = handle_teardown(config, state, req)
            elif command == "list":
                result = handle_list(state)
            elif command == "info":
                result = handle_info(state, req)
            elif command == "resolve-ip":
                result = handle_resolve_ip(config, state, req)
            elif command == "set-digest":
                result = handle_set_digest(state, req)
            else:
                result = {"success": False, "message": f"unknown command: {command}"}
        except Exception as e:
            result = {"success": False, "message": str(e)}

        self._respond(result)

    def _respond(self, data):
        line = json.dumps(data) + "\n"
        self.wfile.write(line.encode())
        self.wfile.flush()


class DaemonServer(socketserver.UnixStreamServer):
    """Unix socket server for the cc-sandbox daemon."""

    def __init__(self, config, state):
        self.config = config
        self.state = state
        # Remove stale socket file
        sock_path = config.socket_path
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        super().__init__(sock_path, DaemonHandler)
        # Set socket permissions: group-readable/writable
        os.chmod(sock_path, 0o660)


def run_daemon(config):
    """Run the cc-sandbox daemon."""
    state = State(config.state_file)
    server = DaemonServer(config, state)
    print(f"cc-sandbox daemon listening on {config.socket_path}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


# --- CLI client ---

def send_command(socket_path, request):
    """Send a command to the daemon and return the response."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(300)  # 5 minute timeout for long operations
    try:
        sock.connect(socket_path)
        payload = json.dumps(request) + "\n"
        sock.sendall(payload.encode())

        # Read response
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk

        return json.loads(data.decode())
    finally:
        sock.close()


def cli_create(args, socket_path):
    """CLI: create a new sandbox."""
    req = {"command": "create"}
    if args.repo:
        req["repo"] = args.repo

    print("Creating sandbox...", flush=True)
    resp = send_command(socket_path, req)

    if not resp.get("success"):
        print(f"Error: {resp.get('message', 'unknown error')}", file=sys.stderr)
        sys.exit(1)

    name = resp["data"]["name"]
    print(f'Sandbox "{name}" created')
    print(f"  SSH: cc-sandbox ssh {name}")


def cli_ssh(args, socket_path):
    """CLI: SSH into a sandbox."""
    print("Waiting for sandbox IP...", flush=True)
    resp = send_command(socket_path, {
        "command": "resolve-ip",
        "name": args.name,
        "timeout": 30,
    })

    if not resp.get("success"):
        print(f"Error: {resp.get('message', 'unknown error')}", file=sys.stderr)
        sys.exit(1)

    ip = resp["data"]["ip"]

    # TODO: StrictHostKeyChecking=no is used because containers generate
    # ephemeral host keys on boot. Fix by having containers request SSH host
    # certificates from step-ca (requires br-deploy egress to the CA).
    os.execvp("ssh", [
        "ssh", "-o", "StrictHostKeyChecking=no",
        f"claude@{ip}",
    ])


def cli_teardown(args, socket_path):
    """CLI: tear down a sandbox."""
    resp = send_command(socket_path, {"command": "teardown", "name": args.name})

    if not resp.get("success"):
        print(f"Error: {resp.get('message', 'unknown error')}", file=sys.stderr)
        sys.exit(1)

    print(resp.get("message", "done"))


def cli_list(_args, socket_path):
    """CLI: list active sandboxes."""
    resp = send_command(socket_path, {"command": "list"})

    if not resp.get("success"):
        print(f"Error: {resp.get('message', 'unknown error')}", file=sys.stderr)
        sys.exit(1)

    sandboxes = resp["data"]["sandboxes"]
    if not sandboxes:
        print("No active sandboxes.")
        return

    # Table output
    print(f"{'NAME':<20} {'IP':<16} {'REPO':<40} {'CREATED'}")
    print("-" * 96)
    for sb in sandboxes:
        repo = sb.get("repo", "")
        if len(repo) > 38:
            repo = "..." + repo[-35:]
        created = sb.get("created_at", "")[:19]
        print(f"{sb['name']:<20} {sb.get('ip', ''):<16} {repo:<40} {created}")


def _read_cli_token():
    """Read the Forgejo token for CLI operations.

    Checks, in order:
      1. CC_SANDBOX_FORGEJO_TOKEN_FILE env var (explicit file path)
      2. ~/.config/cc-sandbox/forgejo-token (default location)
      3. CC_SANDBOX_FORGEJO_TOKEN env var (direct value)
    """
    token_file = os.environ.get("CC_SANDBOX_FORGEJO_TOKEN_FILE", "")
    if token_file:
        return Path(token_file).read_text().strip()

    default_path = Path.home() / ".config" / "cc-sandbox" / "forgejo-token"
    if default_path.exists():
        return default_path.read_text().strip()

    return os.environ.get("CC_SANDBOX_FORGEJO_TOKEN", "")


def cli_rebuild_image(args, socket_path):
    """CLI: build, push, and record the sandbox image.

    Runs directly as the calling user who has nix/skopeo access.
    Sends the resulting digest to the daemon via the Unix socket.
    """
    registry = os.environ.get("CC_SANDBOX_REGISTRY", "")
    image_name = os.environ.get("CC_SANDBOX_IMAGE_NAME", "deployd/claude-sandbox")
    registry_user = os.environ.get("CC_SANDBOX_REGISTRY_USER", os.environ.get("USER", ""))
    ca_cert = os.environ.get("CC_SANDBOX_CA_CERT", "")
    flake_path = os.environ.get("CC_SANDBOX_FLAKE_PATH", ".")
    flake_attr = os.environ.get("CC_SANDBOX_FLAKE_ATTR", "claude-sandbox-image")
    forgejo_token = _read_cli_token()

    if not registry:
        print("Error: CC_SANDBOX_REGISTRY not set", file=sys.stderr)
        sys.exit(1)
    if not forgejo_token:
        print("Error: no Forgejo token found — create ~/.config/cc-sandbox/forgejo-token"
              " or set CC_SANDBOX_FORGEJO_TOKEN_FILE", file=sys.stderr)
        sys.exit(1)
    if not registry_user:
        print("Error: CC_SANDBOX_REGISTRY_USER not set and $USER is empty", file=sys.stderr)
        sys.exit(1)

    print("Building image...", flush=True)
    digest = rebuild_image(socket_path, registry, image_name, registry_user,
                           forgejo_token, ca_cert, flake_path, flake_attr)
    print(f"Image pushed, digest: {digest}")


# --- Main ---

def main():
    parser = argparse.ArgumentParser(
        prog="cc-sandbox",
        description="Claude Code sandbox orchestrator",
    )
    parser.add_argument(
        "--socket", default=os.environ.get("CC_SANDBOX_SOCKET_PATH", "/run/cc-sandbox/cc-sandbox.sock"),
        help="daemon Unix socket path",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # daemon
    subparsers.add_parser("daemon", help="run the cc-sandbox daemon")

    # create
    create_parser = subparsers.add_parser("create", help="create a new sandbox")
    create_parser.add_argument("--repo", help="repo URL to fork and clone into the sandbox")

    # ssh
    ssh_parser = subparsers.add_parser("ssh", help="SSH into a sandbox")
    ssh_parser.add_argument("name", help="sandbox name")

    # teardown
    teardown_parser = subparsers.add_parser("teardown", help="tear down a sandbox")
    teardown_parser.add_argument("name", help="sandbox name")

    # list
    subparsers.add_parser("list", help="list active sandboxes")

    # rebuild-image (runs directly, not via daemon)
    subparsers.add_parser("rebuild-image", help="build, push, and record the sandbox image")

    args = parser.parse_args()

    if args.command == "daemon":
        config = DaemonConfig()
        run_daemon(config)
    else:
        socket_path = args.socket
        handler = {
            "create": cli_create,
            "ssh": cli_ssh,
            "teardown": cli_teardown,
            "list": cli_list,
            "rebuild-image": cli_rebuild_image,
        }[args.command]
        handler(args, socket_path)


if __name__ == "__main__":
    main()
