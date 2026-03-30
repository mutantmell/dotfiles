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
import socket
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

# SSH options for connecting to containers.  Containers generate ephemeral host
# keys on boot and IPs are reused from a pool, so we skip host key verification.
# TODO: replace with SSH host certificates from step-ca (Phase D5).
SSH_OPTS = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR"]

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

        # Registry push credentials
        self.registry_user = cfg.get("registryUser", "cc")

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
            return {"image_digest": ""}
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


# --- Project profiles ---

class Profile:
    """Per-project profile stored in $XDG_STATE_HOME/cc-sandbox/projects/<owner>-<repo>/."""

    def __init__(self, owner, repo):
        self.owner = owner
        self.repo = repo
        self.dir = Path(xdg_state_home()) / "cc-sandbox" / "projects" / f"{owner}-{repo}"
        self.path = self.dir / "profile.json"

    def exists(self):
        return self.path.exists()

    def load(self):
        return json.loads(self.path.read_text())

    def save(self, data):
        self.dir.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(data, indent=2) + "\n")

    @staticmethod
    def list_all():
        projects_dir = Path(xdg_state_home()) / "cc-sandbox" / "projects"
        if not projects_dir.exists():
            return []
        profiles = []
        for entry in sorted(projects_dir.iterdir()):
            profile_path = entry / "profile.json"
            if entry.is_dir() and profile_path.exists():
                data = json.loads(profile_path.read_text())
                profiles.append(data)
        return profiles


# --- Repo detection ---

def detect_repo_from_cwd():
    """Auto-detect repo from cwd via git remote origin. Returns (owner, repo) or None."""
    result = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    try:
        return parse_repo_url(result.stdout.strip())
    except ValueError:
        return None


def resolve_project(args_repo):
    """Resolve a project from args or cwd. Returns (owner, repo)."""
    if args_repo:
        return parse_repo_url(args_repo)
    detected = detect_repo_from_cwd()
    if detected is None:
        print("Error: not in a git repo — specify a repo argument", file=sys.stderr)
        sys.exit(1)
    return detected


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

def deployd_deploy(config, token, name, image, env=None, memory=None, cpus=None, volumes=None):
    """Deploy a container via deployd-api. Returns the container IP."""
    payload = {"name": name, "image": image}
    if env:
        payload["env"] = env
    if memory:
        payload["memory"] = memory
    if cpus:
        payload["cpus"] = cpus
    if volumes:
        payload["volumes"] = volumes
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

def build_image(config):
    """Build the sandbox image and return the nix store output path."""
    result = subprocess.run(
        ["nix", "build", f"{config.flake_path}#{config.flake_attr}",
         "--print-out-paths", "--no-link"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def push_image(config, image_path):
    """Push a docker-archive image to the registry and return its digest."""
    forgejo_token = config.forgejo_token
    if not forgejo_token:
        raise RuntimeError(
            "no Forgejo token found — check forgejoTokenFile in config"
        )

    # Push (with TLS verification via CA cert)
    dest = f"docker://{config.registry}/{config.image_name}:latest"
    skopeo_push = [
        "skopeo", "copy", "--insecure-policy",
        "--dest-creds", f"{config.registry_user}:{forgejo_token}",
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
    return json.loads(result.stdout)["Digest"]


def ensure_image(config, state):
    """Build the image, push only if changed. Returns the digest."""
    image_path = build_image(config)

    data = state.load()
    if data.get("image_store_path") == image_path and data.get("image_digest"):
        return data["image_digest"]

    print("Image changed, pushing...", flush=True)
    digest = push_image(config, image_path)

    data = state.load()
    data["image_digest"] = digest
    data["image_store_path"] = image_path
    state.save(data)
    return digest


def rebuild_image(config, state):
    """Build, push, and record the sandbox image digest (force push)."""
    image_path = build_image(config)
    digest = push_image(config, image_path)

    data = state.load()
    data["image_digest"] = digest
    data["image_store_path"] = image_path
    state.save(data)
    return digest


# --- Dev shell management ---

def build_dev_shell(profile):
    """Build the dev shell if the project has a flake.

    Returns (store_path, lock_hash, env_script_path) or None.
    Skips if no checkout_path or no flake.nix in the checkout.
    Skips the build (returns cached) if flake.lock hash hasn't changed.

    The env_script_path is a file in the profile directory containing the output
    of `nix print-dev-env`, used to activate the environment without re-evaluating
    the flake inside the container.
    """
    data = profile.load() if isinstance(profile, Profile) else profile
    checkout = data.get("checkout_path", "")
    if not checkout:
        return None

    flake_nix = Path(checkout) / "flake.nix"
    if not flake_nix.exists():
        return None

    # Hash flake.lock for staleness check
    flake_lock = Path(checkout) / "flake.lock"
    if flake_lock.exists():
        lock_hash = hashlib.sha256(flake_lock.read_bytes()).hexdigest()
    else:
        lock_hash = ""

    # Determine where to store the env script
    owner = data.get("owner", "")
    repo = data.get("repo", "")
    env_script_path = Path(xdg_state_home()) / "cc-sandbox" / "projects" / f"{owner}-{repo}" / "dev-env.sh"

    # Check if cached dev shell is still current
    cached_hash = data.get("dev_shell_flake_lock_hash", "")
    cached_path = data.get("dev_shell_path", "")
    if cached_hash == lock_hash and cached_path and env_script_path.exists():
        return cached_path, lock_hash, str(env_script_path)

    flake_ref = f"{checkout}#devShells.x86_64-linux.default"

    # Build
    result = subprocess.run(
        ["nix", "build", flake_ref, "--print-out-paths", "--no-link"],
        capture_output=True, text=True, check=True,
    )
    store_path = result.stdout.strip()

    # Generate dev-env.sh via nix print-dev-env
    result = subprocess.run(
        ["nix", "print-dev-env", flake_ref],
        capture_output=True, text=True, check=True,
    )
    env_script_path.parent.mkdir(parents=True, exist_ok=True)
    env_script_path.write_text(result.stdout)

    return store_path, lock_hash, str(env_script_path)


def wait_for_ssh(ip, timeout=60):
    """Poll until TCP port 22 accepts connections. Returns True on success."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            sock = socket.create_connection((ip, 22), timeout=2)
            sock.close()
            return True
        except OSError:
            time.sleep(1)
    return False


def copy_dev_env_script(ip, env_script_path):
    """Copy the dev-env.sh script to the container via scp."""
    subprocess.run(
        ["scp"] + SSH_OPTS + [env_script_path, f"claude@{ip}:/workspace/.dev-env.sh"],
        check=True,
    )


def copy_dev_shell(ip, store_path):
    """Copy a nix store path to the container via ssh-ng.

    Passes SSH options to skip host key verification — containers have
    ephemeral host keys and IPs are reused from a pool.
    """
    env = os.environ.copy()
    env["NIX_SSHOPTS"] = " ".join(SSH_OPTS)
    subprocess.run(
        ["nix", "copy", "--to", f"ssh-ng://claude@{ip}", store_path],
        check=True, env=env,
    )


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

def cmd_init(args, config, _state, _token_mgr):
    """Register a project — fork on Forgejo, create profile."""
    owner, repo = resolve_project(getattr(args, "repo", None))
    profile = Profile(owner, repo)

    if profile.exists():
        print(f"Error: project {owner}/{repo} is already registered", file=sys.stderr)
        sys.exit(1)

    fork_url = forgejo_fork(config, owner, repo)
    upstream_url = f"{config.forgejo_url}/{owner}/{repo}.git"

    # Record checkout_path if auto-detected from cwd
    checkout_path = ""
    if not getattr(args, "repo", None):
        checkout_path = os.getcwd()

    data = {
        "owner": owner,
        "repo": repo,
        "fork_url": fork_url,
        "upstream_url": upstream_url,
        "checkout_path": checkout_path,
        "container_name": None,
        "container_ip": None,
        "created_at": None,
    }
    profile.save(data)

    print(f"Project {owner}/{repo} registered")
    print(f"  Fork: {fork_url}")
    if checkout_path:
        print(f"  Checkout: {checkout_path}")


def cmd_up(args, config, state, token_mgr):
    """Spin up a container from an existing profile."""
    owner, repo = resolve_project(getattr(args, "repo", None))
    profile = Profile(owner, repo)

    if not profile.exists():
        print(f"Error: project {owner}/{repo} not registered — run 'cc-sandbox init' first",
              file=sys.stderr)
        sys.exit(1)

    data = profile.load()

    if data.get("container_name"):
        print(f"Error: project {owner}/{repo} already has a running container: {data['container_name']}",
              file=sys.stderr)
        sys.exit(1)

    # Build image and push if needed
    print("Checking image...", flush=True)
    digest = ensure_image(config, state)

    token = token_mgr.get_token()
    name = generate_hostname(set())
    container_name = f"cc-{name}"
    image_ref = f"{config.registry}/{config.image_name}@{digest}"

    env = {}
    if config.dns_servers:
        env["SANDBOX_DNS"] = config.dns_servers
    env["SANDBOX_REPO_URL"] = data["fork_url"]
    env["SANDBOX_REPO_NAME"] = repo
    env["SANDBOX_GIT_TOKEN"] = config.forgejo_token
    env["SANDBOX_UPSTREAM_URL"] = data["upstream_url"]

    # Named volume for Claude state — persists auth, memories, settings across containers.
    # deployd-helper resolves this to a per-user directory on the host.
    # The container entrypoint chowns /workspace/.claude to the claude user on boot.
    volumes = [{"name": "cc-claude-state", "container": "/workspace/.claude"}]

    print(f"Deploying container for {owner}/{repo}...", flush=True)
    deployd_deploy(
        config, token, container_name, image_ref,
        env=env,
        memory=config.memory_limit or None,
        cpus=config.cpu_limit or None,
        volumes=volumes,
    )

    # Poll for IP
    ip = None
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            ip = deployd_inspect(config, token, container_name)
        except Exception:
            pass
        if ip:
            break
        time.sleep(1)

    data["container_name"] = container_name
    data["container_ip"] = ip
    data["created_at"] = datetime.now(timezone.utc).isoformat()

    # Build dev shell if project has a flake
    dev_shell = build_dev_shell(data)
    if dev_shell:
        store_path, lock_hash, env_script_path = dev_shell
        data["dev_shell_path"] = store_path
        data["dev_shell_flake_lock_hash"] = lock_hash

        copied = False
        if ip:
            print("Waiting for SSH...", flush=True)
            if wait_for_ssh(ip):
                print("Copying dev shell to container...", flush=True)
                try:
                    copy_dev_shell(ip, store_path)
                    copy_dev_env_script(ip, env_script_path)
                    copied = True
                except subprocess.CalledProcessError as e:
                    print(f"Warning: dev shell copy failed: {e}", file=sys.stderr)
            else:
                print("Warning: SSH not ready after 60s, skipping dev shell copy",
                      file=sys.stderr)
        else:
            print("Warning: no IP available, skipping dev shell copy", file=sys.stderr)

        if not copied:
            # Don't record dev shell in profile — ssh would try to source a
            # missing dev-env.sh on the container.
            data.pop("dev_shell_path", None)
            data.pop("dev_shell_flake_lock_hash", None)

    profile.save(data)

    print(f"Sandbox ready: {container_name}")
    if ip:
        print("  SSH: cc-sandbox ssh")
    else:
        print("  IP not yet available — SSH will poll on connect")


def cmd_down(args, config, _state, token_mgr):
    """Tear down the container for a project. Profile persists."""
    owner, repo = resolve_project(getattr(args, "repo", None))
    profile = Profile(owner, repo)

    if not profile.exists():
        print(f"Error: project {owner}/{repo} not registered", file=sys.stderr)
        sys.exit(1)

    data = profile.load()

    if not data.get("container_name"):
        print(f"Error: project {owner}/{repo} has no active container", file=sys.stderr)
        sys.exit(1)

    token = token_mgr.get_token()
    container_name = data["container_name"]

    try:
        deployd_teardown(config, token, container_name)
    except Exception as e:
        print(f"Error: teardown failed: {e}", file=sys.stderr)
        sys.exit(1)

    data["container_name"] = None
    data["container_ip"] = None
    data["created_at"] = None
    profile.save(data)

    print(f"Container for {owner}/{repo} torn down")


def cmd_ssh(args, config, _state, token_mgr):
    """SSH into the active container for a project."""
    owner, repo = resolve_project(getattr(args, "repo", None))
    profile = Profile(owner, repo)

    if not profile.exists():
        print(f"Error: project {owner}/{repo} not registered", file=sys.stderr)
        sys.exit(1)

    data = profile.load()

    if not data.get("container_name"):
        print(f"Error: project {owner}/{repo} has no active container", file=sys.stderr)
        sys.exit(1)

    cached_ip = data.get("container_ip")
    if not cached_ip:
        token = token_mgr.get_token()
        container_name = data["container_name"]

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
            print("Error: sandbox IP not available after 30s", file=sys.stderr)
            sys.exit(1)

        data["container_ip"] = ip
        profile.save(data)
        cached_ip = ip

    ssh_cmd = ["ssh"] + SSH_OPTS

    dev_shell = data.get("dev_shell_path")
    no_develop = getattr(args, "no_develop", False)
    if dev_shell and not no_develop:
        repo_name = data.get("repo", "")
        work_dir = f"/workspace/{repo_name}" if repo_name else "/workspace"
        ssh_cmd += ["-t", f"claude@{cached_ip}",
                    f"cd {work_dir} && source /workspace/.dev-env.sh && exec bash"]
    else:
        ssh_cmd.append(f"claude@{cached_ip}")

    os.execvp("ssh", ssh_cmd)


def cmd_list(_args, _config, _state, _token_mgr):
    """List registered projects and their status."""
    profiles = Profile.list_all()

    if not profiles:
        print("No registered projects.")
        return

    print(f"{'PROJECT':<30} {'STATUS':<10} {'IP':<16} {'REPO'}")
    print("-" * 90)
    for info in profiles:
        project = f"{info['owner']}/{info['repo']}"
        status = "running" if info.get("container_name") else "stopped"
        ip = info.get("container_ip") or ""
        upstream = info.get("upstream_url", "")
        if len(upstream) > 38:
            upstream = "..." + upstream[-35:]
        print(f"{project:<30} {status:<10} {ip:<16} {upstream}")


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

    # init
    init_parser = subparsers.add_parser("init", help="register a project")
    init_parser.add_argument("repo", nargs="?", default=None,
                             help="owner/repo or URL (auto-detects from cwd if omitted)")

    # up
    up_parser = subparsers.add_parser("up", help="spin up a container for a project")
    up_parser.add_argument("repo", nargs="?", default=None,
                           help="owner/repo or URL (auto-detects from cwd if omitted)")

    # down
    down_parser = subparsers.add_parser("down", help="tear down a project's container")
    down_parser.add_argument("repo", nargs="?", default=None,
                             help="owner/repo or URL (auto-detects from cwd if omitted)")

    # ssh
    ssh_parser = subparsers.add_parser("ssh", help="SSH into a project's container")
    ssh_parser.add_argument("repo", nargs="?", default=None,
                            help="owner/repo or URL (auto-detects from cwd if omitted)")
    ssh_parser.add_argument("--no-develop", action="store_true",
                            help="plain shell instead of nix develop")

    # list
    subparsers.add_parser("list", help="list registered projects")

    # rebuild-image
    subparsers.add_parser("rebuild-image", help="build, push, and record the sandbox image")

    args = parser.parse_args()

    config = Config()
    state = State()
    token_mgr = TokenManager(config)

    handler = {
        "init": cmd_init,
        "up": cmd_up,
        "down": cmd_down,
        "ssh": cmd_ssh,
        "list": cmd_list,
        "rebuild-image": cmd_rebuild_image,
    }[args.command]
    handler(args, config, state, token_mgr)


if __name__ == "__main__":
    main()
