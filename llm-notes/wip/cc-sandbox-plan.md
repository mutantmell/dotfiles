# cc-sandbox: Claude Code Sandbox Orchestrator

## Context

With deployd validated end-to-end (D0 complete), the next step is automating sandbox lifecycle. Currently, creating a Claude Code sandbox requires manually running a 200-line shell script that builds an image, pushes it, authenticates with Keycloak, deploys via the API, discovers the container IP, and SSHs in. cc-sandbox automates this into `cc-sandbox create` / `cc-sandbox ssh <name>` / `cc-sandbox teardown <name>`.

## Architecture

```
  [edith (10.97.21.42, lab zone)]
    cc-sandbox daemon (systemd service)
      - Unix socket: /run/cc-sandbox/cc-sandbox.sock
      - Holds: Keycloak creds, Forgejo token (sops)
      - State: /var/lib/cc-sandbox/state.json
      |
      | HTTPS (password grant → Bearer token)
      v
    [roer.internal] → deployd-api → deployd-helper → nerdctl + Kata
      |
      | deploy response includes container IP (new)
      v
    [sandbox container on br-deploy (10.100.0.x)]
      - Direct route from edith exists
      - cc-sandbox SSH key authorized in image
```

## Language: Python

cc-sandbox is a thin orchestration layer — it shells out to `nix build`, `skopeo`, and `ssh`, and makes a few HTTP calls. No concurrent connections, no security-critical parsing, no performance requirements. Python with `requests` and standard library is sufficient and much faster to develop than Rust.

Packaging: `pkgs.python3Packages.buildPythonApplication` or a simple `writeShellApplication` wrapper around a Python script with `python3.withPackages`. The daemon and CLI are a single Python file (or small package) with `argparse` subcommands.

## Prerequisite: deployd-helper returns container IP on deploy

Currently `deploy()` returns `HelperResponse::ok("container 'X' deployed")` with no IP data. The `data` field exists but is unused. We need to:

1. **deployd-helper** (`packages/deployd-helper/src/executor.rs`): After successful `systemctl start`, run `nerdctl inspect <name>` to get the container IP, return it in `HelperResponse.data`:
   ```json
   {"ip": "10.100.0.5"}
   ```

2. **deployd-api** (`packages/deployd-api/src/routes.rs`): Already forwards `resp.data` to the HTTP caller (`helper_ok_json(&resp)` includes data). No API changes needed.

Backwards-compatible — existing callers that ignore `data` are unaffected.

**Files modified:**
- `packages/deployd-helper/src/executor.rs` — add `nerdctl inspect` after start, populate `data` with IP

## Phase 1: Python Package + CLI/Daemon

**New files:**
- `packages/cc-sandbox/cc_sandbox.py` — single-file Python application:
  - `argparse` subcommands: `daemon`, `create [--repo <url>]`, `ssh <name>`, `teardown <name>`, `list`
  - Daemon mode: `socketserver.UnixStreamServer`, synchronous (single client at a time is fine)
  - CLI mode: connect to Unix socket, send JSON-line request, print response
  - Config from env vars: socket path, state file, secret file paths, API URLs, registry URL, flake path, SSH key path
- `packages/cc-sandbox/default.nix` — Nix package:
  - `python3.withPackages (ps: [ ps.requests ])` for runtime
  - Runtime deps: `nix`, `skopeo`, `openssh` (for SSH to containers)
  - Wrap as `cc-sandbox` binary

**Modified files:**
- `flake.nix` — add `cc-sandbox` package

## Phase 2: deployd + Keycloak Integration

In `cc_sandbox.py`:

- `get_token(auth_url, username, password)` — Keycloak password grant via `deployd-operator` client, returns access token. Cache token, refresh on expiry (parse `expires_in` from response).
- `deploy(api_url, token, name, image)` — `requests.post()` to `/api/v1/deploy`, returns container IP from `response.json()["data"]["ip"]`
- `teardown(api_url, token, name)` — `requests.delete()` to `/api/v1/teardown/{name}`

CA cert: pass internal CA cert path to `requests` via `verify=` parameter.

**Protocol (daemon ↔ CLI, Unix socket, JSON-line):**
```
→ {"command":"create","repo":"https://creil.internal/user/repo"}
← {"success":true,"data":{"name":"silver-blade","ip":"10.100.0.5"}}

→ {"command":"teardown","name":"silver-blade"}
← {"success":true,"message":"torn down"}

→ {"command":"list"}
← {"success":true,"data":{"sandboxes":[...]}}

→ {"command":"info","name":"silver-blade"}
← {"success":true,"data":{"name":"silver-blade","ip":"10.100.0.5","repo":"..."}}
```

## Phase 3: Image Build + Push, State, Hostnames

In `cc_sandbox.py`:

**Image management:**
- `ensure_image(flake_path, registry, forgejo_token)`:
  - Run `nix build <flake>#claude-sandbox-image --print-out-paths --no-link`
  - Push via `skopeo copy docker-archive:<path> docker://<registry>/deployd/claude-sandbox:latest`
  - Fetch digest via `skopeo inspect`
  - Cache digest in state file; skip rebuild if cached (add `--rebuild` flag to force)

**State file** (`/var/lib/cc-sandbox/state.json`):
```json
{
  "sandboxes": {
    "silver-blade": {
      "container_name": "cc-silver-blade",
      "ip": "10.100.0.5",
      "repo": "https://creil.internal/cc/repo.git",
      "created_at": "2026-03-26T10:00:00Z"
    }
  },
  "image_digest": "sha256:abc123..."
}
```
- `fcntl.flock()` for file-level locking

**Hostname generation:**
- Two lists of Trails-themed words drawn from craft/arts naming (e.g., Silver, Heavy, Phantom, Crimson, Azure, Steel, Raging + Blade, Streak, Fang, Wing, Storm, Cross, Lance)
- `random.choice()` from each list → `silver-blade`
- Collision check against current state
- Container name: `cc-silver-blade` (prefixed to avoid deployd namespace collisions)

## Phase 4: Forgejo Integration + Repo Cloning

In `cc_sandbox.py`:

- `fork_repo(forgejo_url, token, owner, repo)` → `requests.post()` to `/api/v1/repos/{owner}/{repo}/forks` with `organization: "cc"`
- `clone_into_container(ip, ssh_key, repo_url)` → `subprocess.run(["ssh", ...])` to `claude@<ip>`, run `git clone <url> /workspace/<repo>`
- Parse repo URL to extract owner/name (support `https://creil.internal/owner/repo` and `owner/repo` shorthand)

## Phase 5: NixOS Wiring on edith

**New files:**
- `hosts/calvard/incus/guests/edith/modules/cc-sandbox.nix` — systemd service + config:
  - Service runs as `cc-sandbox` system user
  - `mutantmell` added to `cc-sandbox` group (socket access)
  - Sops secrets: keycloak-user, keycloak-pass, forgejo-token, cc-sandbox SSH private key
  - Impermanence: persist `/var/lib/cc-sandbox`
  - Env vars: secret file paths, API URLs, flake path, registry URL, CA cert path, SSH key path
  - `environment.systemPackages = [ pkgs.mmell.cc-sandbox ]` for CLI access

**Modified files:**
- `hosts/calvard/incus/guests/edith/default.nix` — import `./modules/cc-sandbox.nix`
- `hosts/calvard/incus/guests/edith/sops.nix` — add cc-sandbox secrets
- `packages/claude-sandbox-image/default.nix` — add cc-sandbox SSH public key to authorized_keys
- `lib/common/data/keys.json` — add `cc-sandbox` SSH public key

**Manual steps:**
- Generate cc-sandbox SSH keypair, add private key to edith sops secrets
- Create "cc" user on Forgejo (creil), generate personal access token with write:repository + write:package
- Add Keycloak user or reuse existing user in "deploy" group
- Encrypt new secrets with sops

## Phase 6: Update deployd integration doc

- `llm-notes/wip/deployd-integration.md` — mark D0 complete, document cc-sandbox

## Create Flow (end-to-end)

1. CLI sends `create` (with optional repo URL) to daemon via Unix socket
2. Daemon generates Trails-themed hostname → `silver-blade`, container name → `cc-silver-blade`
3. Daemon checks if image digest is cached; if not, builds image (`nix build`), pushes to creil (`skopeo`), extracts digest
4. Daemon gets Keycloak token (cached with expiry refresh)
5. Daemon calls deployd-api POST `/api/v1/deploy` with `{name: "cc-silver-blade", image: "creil.internal/deployd/claude-sandbox@sha256:..."}`
6. deployd-helper starts container, runs `nerdctl inspect`, returns IP in response data
7. If repo specified: daemon forks on Forgejo under "cc" user, SSHs to `claude@<ip>` to clone
8. Daemon writes state entry, returns `{name: "silver-blade", ip: "10.100.0.5"}` to CLI
9. CLI prints: `Sandbox "silver-blade" ready at 10.100.0.5 — run: cc-sandbox ssh silver-blade`

## Verification

1. `nix build .#cc-sandbox` — package builds
2. `nix build .#checks.x86_64-linux.deployd` — deployd test still passes (with IP-in-response change)
3. Deploy edith config, run `cc-sandbox create`, verify container starts and IP is reachable
4. `cc-sandbox ssh <name>` drops into container shell
5. `cc-sandbox create --repo creil.internal/user/repo` forks and clones
6. `cc-sandbox list` shows active sandboxes
7. `cc-sandbox teardown <name>` cleans up container and state

## Implementation Order

1. **deployd-helper IP-in-response** (prerequisite, small Rust change)
2. **Phases 1-3** — Python package with daemon, CLI, deployd client, state, hostnames, image management (these are all in one file, natural to build together)
3. **Phase 4** — Forgejo integration (can be deferred if "cc" user isn't set up yet)
4. **Phase 5** — NixOS wiring on edith
