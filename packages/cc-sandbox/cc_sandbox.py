#!/usr/bin/env python3
"""cc-sandbox: Claude Code sandbox orchestrator.

A user-owned CLI tool for creating isolated Claude Code coding environments via deployd.
Reads config from ~/.config/cc-sandbox/config.json, manages state in
$XDG_STATE_HOME/cc-sandbox/, and authenticates via OAuth (auth code + PKCE with
device grant fallback).

Security notes:
  - Container name injection: the CLI prefixes all names with "cc-" and
    deployd-helper validates names. For multi-user scenarios, add per-user
    namespacing or token-based scoping.
  - SSH host key verification: cc-sandbox ssh uses StrictHostKeyChecking=no
    because containers generate ephemeral host keys on boot. A proper fix
    is to have containers request SSH host certificates from step-ca, which
    requires br-deploy egress to the CA. Deferred to Phase D5.
"""

import argparse
import fcntl
import hashlib
import json
import os
import random
import secrets
import subprocess
import sys
import time
import webbrowser
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import base64
from urllib.parse import urlparse, urlencode, parse_qs

import requests as http_requests

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


# --- XDG helpers ---

def xdg_config_home():
    return os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))


def xdg_state_home():
    return os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state"))


# --- Configuration ---

class Config:
    """Configuration from ~/.config/cc-sandbox/config.json."""

    def __init__(self):
        config_path = Path(xdg_config_home()) / "cc-sandbox" / "config.json"
        if not config_path.exists():
            raise RuntimeError(
                f"config file not found: {config_path}\n"
                "Install cc-sandbox via home-manager to generate this file."
            )
        cfg = json.loads(config_path.read_text())

        self.api_url = cfg["apiUrl"]
        self.registry = cfg["registry"]
        self.forgejo_url = cfg.get("forgejoUrl", f"https://{self.registry}")
        self.image_name = cfg.get("imageName", "deployd/claude-sandbox")
        self.ca_cert = cfg.get("caCert", "")
        self.dns_servers = cfg.get("dnsServers", "")
        self.memory_limit = cfg.get("memoryLimit", "4g")
        self.cpu_limit = cfg.get("cpuLimit", "2")
        self.flake_path = cfg.get("flakePath", ".")
        self.flake_attr = cfg.get("flakeAttr", "claude-sandbox-image")

        # OAuth
        self.auth_base_url = cfg["authBaseUrl"]
        self.client_id = cfg.get("clientId", "cc-sandbox")

        # Forgejo token from file
        self.forgejo_token_file = cfg.get("forgejoTokenFile", "")
        self._forgejo_token = None

    @property
    def forgejo_token(self):
        if self._forgejo_token is None:
            if self.forgejo_token_file and Path(self.forgejo_token_file).exists():
                self._forgejo_token = Path(self.forgejo_token_file).read_text().strip()
            else:
                self._forgejo_token = ""
        return self._forgejo_token

    def requests_verify(self):
        """Return the verify parameter for requests calls."""
        return self.ca_cert if self.ca_cert else True


# --- State management ---

class State:
    """JSON state file with file locking."""

    def __init__(self, path=None):
        if path is None:
            path = Path(xdg_state_home()) / "cc-sandbox" / "state.json"
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


# --- OAuth token management ---

class TokenManager:
    """OAuth token management with auth code + PKCE and device grant fallback.

    Token cache: $XDG_STATE_HOME/cc-sandbox/token.json (mode 0600)
    """

    def __init__(self, config):
        self.config = config
        self.token_path = Path(xdg_state_home()) / "cc-sandbox" / "token.json"
        self._authorize_url = f"{config.auth_base_url}/protocol/openid-connect/auth"
        self._token_url = f"{config.auth_base_url}/protocol/openid-connect/token"
        self._device_url = f"{config.auth_base_url}/protocol/openid-connect/auth/device"

    def get_token(self):
        """Get a valid access token, refreshing or re-authenticating as needed."""
        cached = self._load_cache()
        if cached:
            # Valid token with >30s remaining
            if cached.get("expires_at", 0) > time.time() + 30:
                return cached["access_token"]

            # Try refresh
            if cached.get("refresh_token"):
                refreshed = self._try_refresh(cached["refresh_token"])
                if refreshed:
                    return refreshed

        # No valid token — authenticate
        return self._authenticate()

    def _load_cache(self):
        if not self.token_path.exists():
            return None
        try:
            return json.loads(self.token_path.read_text())
        except (json.JSONDecodeError, OSError):
            return None

    def _save_cache(self, token_response):
        self.token_path.parent.mkdir(parents=True, exist_ok=True)
        cache = {
            "access_token": token_response["access_token"],
            "refresh_token": token_response.get("refresh_token", ""),
            "expires_at": time.time() + token_response.get("expires_in", 300),
        }
        self.token_path.write_text(json.dumps(cache, indent=2) + "\n")
        self.token_path.chmod(0o600)
        return cache["access_token"]

    def _try_refresh(self, refresh_token):
        try:
            resp = http_requests.post(
                self._token_url,
                data={
                    "grant_type": "refresh_token",
                    "client_id": self.config.client_id,
                    "refresh_token": refresh_token,
                },
                verify=self.config.requests_verify(),
            )
            if resp.status_code == 200:
                return self._save_cache(resp.json())
        except Exception:
            pass
        return None

    def _authenticate(self):
        if self._browser_available():
            return self._auth_code_pkce()
        else:
            return self._device_grant()

    def _browser_available(self):
        # No browser if SSH session or no display
        if os.environ.get("SSH_CONNECTION"):
            return False
        if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
            return False
        return True

    def _auth_code_pkce(self):
        """Authorization code flow with PKCE (S256)."""
        # Generate PKCE challenge
        code_verifier = secrets.token_urlsafe(64)
        code_challenge = hashlib.sha256(code_verifier.encode()).digest()
        code_challenge_b64 = base64.urlsafe_b64encode(code_challenge).rstrip(b"=").decode()

        state = secrets.token_urlsafe(32)
        result = {"code": None, "error": None}

        # Start localhost callback server
        class CallbackHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                params = parse_qs(urlparse(self.path).query)
                if params.get("state", [None])[0] != state:
                    result["error"] = "state mismatch"
                elif "error" in params:
                    result["error"] = params["error"][0]
                elif "code" in params:
                    result["code"] = params["code"][0]
                else:
                    result["error"] = "no code in callback"

                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                if result["code"]:
                    self.wfile.write(b"<html><body><h2>Authentication successful.</h2>"
                                     b"<p>You can close this tab.</p></body></html>")
                else:
                    msg = result.get("error", "unknown error")
                    self.wfile.write(f"<html><body><h2>Authentication failed: {msg}</h2></body></html>".encode())

            def log_message(self, format, *args):
                pass  # Suppress HTTP server logs

        server = HTTPServer(("127.0.0.1", 0), CallbackHandler)
        server.timeout = 120  # seconds — give up if browser auth not completed
        port = server.server_address[1]
        redirect_uri = f"http://localhost:{port}"

        auth_params = urlencode({
            "response_type": "code",
            "client_id": self.config.client_id,
            "redirect_uri": redirect_uri,
            "scope": "openid",
            "state": state,
            "code_challenge": code_challenge_b64,
            "code_challenge_method": "S256",
        })
        auth_url = f"{self._authorize_url}?{auth_params}"

        print("Opening browser for authentication...", flush=True)
        webbrowser.open(auth_url)

        # Handle one request (the callback)
        server.handle_request()
        server.server_close()

        if result["error"]:
            raise RuntimeError(f"authentication failed: {result['error']}")
        if not result["code"]:
            raise RuntimeError("authentication timed out or no authorization code received")

        # Exchange code for tokens
        resp = http_requests.post(
            self._token_url,
            data={
                "grant_type": "authorization_code",
                "client_id": self.config.client_id,
                "code": result["code"],
                "redirect_uri": redirect_uri,
                "code_verifier": code_verifier,
            },
            verify=self.config.requests_verify(),
        )
        resp.raise_for_status()
        return self._save_cache(resp.json())

    def _device_grant(self):
        """Device authorization grant (RFC 8628) for headless sessions."""
        resp = http_requests.post(
            self._device_url,
            data={
                "client_id": self.config.client_id,
                "scope": "openid",
            },
            verify=self.config.requests_verify(),
        )
        resp.raise_for_status()
        device = resp.json()

        verification_uri = device.get("verification_uri_complete") or device.get("verification_uri")
        user_code = device.get("user_code", "")

        print(f"\nTo authenticate, open: {verification_uri}", flush=True)
        if user_code:
            print(f"And enter code: {user_code}", flush=True)
        print("Waiting for authorization...", flush=True)

        interval = device.get("interval", 5)
        expires_in = device.get("expires_in", 600)
        deadline = time.time() + expires_in
        device_code = device["device_code"]

        while time.time() < deadline:
            time.sleep(interval)
            resp = http_requests.post(
                self._token_url,
                data={
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id": self.config.client_id,
                    "device_code": device_code,
                },
                verify=self.config.requests_verify(),
            )
            if resp.status_code == 200:
                return self._save_cache(resp.json())

            try:
                error = resp.json().get("error", "")
            except (ValueError, KeyError):
                raise RuntimeError(
                    f"device authorization failed: HTTP {resp.status_code}"
                )
            if error == "authorization_pending":
                continue
            elif error == "slow_down":
                interval += 5
                continue
            else:
                raise RuntimeError(f"device authorization failed: {error}")

        raise RuntimeError("device authorization timed out")


# --- deployd API client ---

def deployd_deploy(config, token, name, image, env=None, memory=None, cpus=None):
    """Deploy a container via deployd-api. Returns the container IP."""
    payload = {"name": name, "image": image}
    if env:
        payload["env"] = env
    if memory:
        payload["memory"] = memory
    if cpus:
        payload["cpus"] = cpus
    resp = http_requests.post(
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


def deployd_inspect(config, token, name):
    """Inspect a container via deployd-api. Returns the IP if available."""
    resp = http_requests.get(
        f"{config.api_url}/inspect/{name}",
        headers={"Authorization": f"Bearer {token}"},
        verify=config.requests_verify(),
    )
    resp.raise_for_status()
    body = resp.json()
    if "data" in body and body["data"]:
        return body["data"].get("ip")
    return None


def deployd_teardown(config, token, name):
    """Tear down a container via deployd-api."""
    resp = http_requests.delete(
        f"{config.api_url}/teardown/{name}",
        headers={"Authorization": f"Bearer {token}"},
        verify=config.requests_verify(),
    )
    resp.raise_for_status()
    return resp.json()


# --- Image management ---

def rebuild_image(config, state):
    """Build, push, and record the sandbox image digest.

    Runs as the calling user — requires nix and skopeo in PATH.
    Writes the digest to state directly.
    """
    forgejo_token = config.forgejo_token
    if not forgejo_token:
        raise RuntimeError(
            "no Forgejo token found — check forgejoTokenFile in config"
        )

    registry_user = os.environ.get("CC_SANDBOX_REGISTRY_USER", os.environ.get("USER", ""))
    if not registry_user:
        raise RuntimeError("CC_SANDBOX_REGISTRY_USER not set and $USER is empty")

    # Build
    result = subprocess.run(
        ["nix", "build", f"{config.flake_path}#{config.flake_attr}",
         "--print-out-paths", "--no-link"],
        capture_output=True, text=True, check=True,
    )
    image_path = result.stdout.strip()

    # Push (with TLS verification via CA cert)
    dest = f"docker://{config.registry}/{config.image_name}:latest"
    skopeo_push = [
        "skopeo", "copy", "--insecure-policy",
        "--dest-creds", f"{registry_user}:{forgejo_token}",
        f"docker-archive:{image_path}", dest,
    ]
    if config.ca_cert:
        skopeo_push += ["--dest-cert-dir", str(Path(config.ca_cert).parent)]
    else:
        skopeo_push += ["--dest-tls-verify=false"]
    subprocess.run(skopeo_push, check=True)

    # Get digest (with TLS verification via CA cert)
    skopeo_inspect = [
        "skopeo", "inspect", "--insecure-policy",
        f"docker://{config.registry}/{config.image_name}:latest",
    ]
    if config.ca_cert:
        skopeo_inspect += ["--cert-dir", str(Path(config.ca_cert).parent)]
    else:
        skopeo_inspect += ["--tls-verify=false"]
    result = subprocess.run(skopeo_inspect, capture_output=True, text=True, check=True)
    digest = json.loads(result.stdout)["Digest"]

    # Write digest to state directly
    data = state.load()
    data["image_digest"] = digest
    state.save(data)

    return digest


# --- Forgejo API client ---

def forgejo_fork(config, owner, repo):
    """Fork a repo under the 'cc' user on Forgejo. Returns the clone URL."""
    resp = http_requests.post(
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


# --- CLI commands ---

def cmd_create(args, config, state, token_mgr):
    """Create a new sandbox."""
    data = state.load()

    # Check that an image digest exists (set by `cc-sandbox rebuild-image`)
    digest = data.get("image_digest", "")
    if not digest:
        print("Error: no image digest available — run 'cc-sandbox rebuild-image' first",
              file=sys.stderr)
        sys.exit(1)

    token = token_mgr.get_token()
    name = generate_hostname(set(data["sandboxes"].keys()))
    container_name = f"cc-{name}"
    image_ref = f"{config.registry}/{config.image_name}@{digest}"

    # Fork repo on Forgejo if specified (before deploy, so we have the URL)
    repo_param = args.repo or ""
    fork_url = ""
    env = {}
    if config.dns_servers:
        env["SANDBOX_DNS"] = config.dns_servers
    if repo_param:
        owner, repo_name = parse_repo_url(repo_param)
        fork_url = forgejo_fork(config, owner, repo_name)
        env["SANDBOX_REPO_URL"] = fork_url
        env["SANDBOX_REPO_NAME"] = repo_name
        env["SANDBOX_GIT_TOKEN"] = config.forgejo_token
        env["SANDBOX_UPSTREAM_URL"] = f"{config.forgejo_url}/{owner}/{repo_name}.git"

    print("Creating sandbox...", flush=True)
    deployd_deploy(
        config, token, container_name, image_ref,
        env=env or None,
        memory=config.memory_limit or None,
        cpus=config.cpu_limit or None,
    )

    # Save state (IP resolved lazily via inspect when needed)
    data["sandboxes"][name] = {
        "container_name": container_name,
        "repo": fork_url,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    state.save(data)

    print(f'Sandbox "{name}" created')
    print(f"  SSH: cc-sandbox ssh {name}")


def cmd_ssh(args, config, state, token_mgr):
    """SSH into a sandbox."""
    name = args.name
    data = state.load()

    if name not in data["sandboxes"]:
        print(f"Error: sandbox '{name}' not found", file=sys.stderr)
        sys.exit(1)

    # Return cached IP if available
    cached_ip = data["sandboxes"][name].get("ip", "")
    if not cached_ip:
        token = token_mgr.get_token()
        container_name = data["sandboxes"][name]["container_name"]

        print("Waiting for sandbox IP...", flush=True)
        deadline = time.time() + 30
        ip = None
        while time.time() < deadline:
            try:
                ip = deployd_inspect(config, token, container_name)
            except Exception:
                pass
            if ip:
                break
            time.sleep(1)

        if not ip:
            print(f"Error: sandbox '{name}' IP not available after 30s", file=sys.stderr)
            sys.exit(1)

        # Cache the IP
        data = state.load()
        if name in data["sandboxes"]:
            data["sandboxes"][name]["ip"] = ip
            state.save(data)
        cached_ip = ip

    # TODO: StrictHostKeyChecking=no is used because containers generate
    # ephemeral host keys on boot. Fix by having containers request SSH host
    # certificates from step-ca (requires br-deploy egress to the CA).
    os.execvp("ssh", [
        "ssh", "-o", "StrictHostKeyChecking=no",
        f"claude@{cached_ip}",
    ])


def cmd_teardown(args, config, state, token_mgr):
    """Tear down a sandbox."""
    name = args.name
    data = state.load()

    if name not in data["sandboxes"]:
        print(f"Error: sandbox '{name}' not found", file=sys.stderr)
        sys.exit(1)

    token = token_mgr.get_token()
    container_name = data["sandboxes"][name]["container_name"]

    try:
        deployd_teardown(config, token, container_name)
    except Exception as e:
        print(f"Error: teardown failed: {e}", file=sys.stderr)
        sys.exit(1)

    del data["sandboxes"][name]
    state.save(data)

    print(f"Sandbox '{name}' torn down")


def cmd_list(_args, _config, state, _token_mgr):
    """List active sandboxes."""
    data = state.load()
    sandboxes = data.get("sandboxes", {})

    if not sandboxes:
        print("No active sandboxes.")
        return

    print(f"{'NAME':<20} {'IP':<16} {'REPO':<40} {'CREATED'}")
    print("-" * 96)
    for name, info in sandboxes.items():
        repo = info.get("repo", "")
        if len(repo) > 38:
            repo = "..." + repo[-35:]
        created = info.get("created_at", "")[:19]
        print(f"{name:<20} {info.get('ip', ''):<16} {repo:<40} {created}")


def cmd_rebuild_image(_args, config, state, _token_mgr):
    """Build, push, and record the sandbox image."""
    print("Building image...", flush=True)
    digest = rebuild_image(config, state)
    print(f"Image pushed, digest: {digest}")


# --- Main ---

def main():
    parser = argparse.ArgumentParser(
        prog="cc-sandbox",
        description="Claude Code sandbox orchestrator",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

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

    # rebuild-image
    subparsers.add_parser("rebuild-image", help="build, push, and record the sandbox image")

    args = parser.parse_args()

    config = Config()
    state = State()
    token_mgr = TokenManager(config)

    handler = {
        "create": cmd_create,
        "ssh": cmd_ssh,
        "teardown": cmd_teardown,
        "list": cmd_list,
        "rebuild-image": cmd_rebuild_image,
    }[args.command]
    handler(args, config, state, token_mgr)


if __name__ == "__main__":
    main()
