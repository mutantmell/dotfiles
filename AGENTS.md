# AGENTS.md

This file is the model-neutral operating guide for AI coding agents working in this repository. `CLAUDE.md` exists only as a Claude-specific compatibility pointer; keep shared workflow guidance here.

## Repository Shape

This is a Nix flake for a homelab fleet: NixOS hosts, a router module, microVM/Incus guests, OpenWrt device configuration, deployment scripts, and a locked-down KubeVirt dev-machine environment for AI-assisted development.

Important directories:

- `modules/` - reusable NixOS modules. Top-level modules should stay extractable and avoid project-specific host assumptions.
- `modules/common/` - project-specific coordination modules shared across hosts.
- `lib/common/data/network.nix` - network registry and host/address source of truth.
- `hosts/` - concrete host and guest configurations.
- `tests/modules/` - NixOS VM integration tests.
- `tests/lib/` - pure Nix evaluation tests.
- `docs/` - current operator-facing documentation.
- `llm-notes/` - plans, specs, reports, and historical design notes. Treat code and `docs/` as current source of truth when they disagree with old plans.

## Build And Test Commands

Use the repo runner instead of `nix flake check`. This flake has many NixOS evaluations, and a single `nix flake check` process can accumulate enough memory to be OOM-killed.

```bash
# Format all Nix files through treefmt/alejandra.
nix fmt

# Preferred agent preflight.
./scripts/agent-preflight.sh --quick
./scripts/agent-preflight.sh --full

# Run all checks in separate Nix processes.
./scripts/run-checks.sh
./scripts/run-checks.sh -j4

# Run specific checks.
./scripts/run-checks.sh router6-firewall network-registry
nix build .#checks.x86_64-linux.<name>

# Run pure Nix eval tests directly.
nix-instantiate --eval --strict tests/lib/<file>.nix

# Run a VM test interactively.
nix build .#checks.x86_64-linux.<name>.driverInteractive
./result/bin/nixos-test-driver
```

OpenWrt commands:

```bash
nix build .#openwrtConfigurations.<device-name>
nix run .#openwrt-build -- <device-name>
nix run .#openwrt-build -- <device-name> --no-secrets
nix run .#openwrt-show-config -- <device-name>
nix run .#openwrt-deploy -- <device-name> <device-ip>
```

Guest setup commands:

```bash
./scripts/setup-guest.sh <parent-hostname> <guest-name> --target root@<host-ip>
./scripts/setup-guest.sh <parent-hostname> <guest-name> --output-dir <dir>
```

## Dev-Machine Expectations

The dev-machine runs the agent in a devcontainer inside a KubeVirt VM. The VM is the primary security boundary; the inner container still keeps defense-in-depth settings where practical.

Expected capabilities:

- `/dev/kvm` is available in the devcontainer for NixOS VM tests.
- Nix sandboxing is enabled inside the devcontainer.
- Codex/bubblewrap command sandboxing should work. The devcontainer runs through rootful Podman, bind-mounts the VM host `/nix`, and uses the VM host nix-daemon for sandboxed and uid-range builds.
- `kubectl`, `virtctl`, `devpod`, and registry push tools stay on the operator side, not inside the agent container.

Smoke test after dev-machine image/runtime changes:

```bash
./scripts/dev-machine-smoke.sh
```

## Submitting Changes With AGit

This repo uses Forgejo AGit flow for pull requests from the locked-down dev machine. Do not push directly to `main`, and do not look for a PR API token, `tea`, `gh`, or web UI flow. The dev machine should only need its scoped git push credential.

Committing and opening a PR is the default workflow for a coherent unit of work. `refs/for/main` proposes a PR; it does not write protected `main` directly.

```bash
git push origin HEAD:refs/for/main -o topic="<topic>" \
  -o title="<title>" -o description="<inline markdown body>"

git push origin HEAD:refs/for/main -o topic="<topic>"

git push origin HEAD:refs/for/main -o topic="<topic>" -o force-push=true
```

Rules:

- One PR per task is the baseline; reuse the same `topic` for iterations.
- Push options cannot carry real multi-line descriptions. For a multi-paragraph PR body, omit `-o description` and put the body in the lead commit message.
- Run `./scripts/agent-preflight.sh --quick` or the relevant targeted checks before pushing. Use `--full` when touching shared modules, test infrastructure, network policy, deployment scripts, or dev-machine images.
- Irreversible or outward-facing actions beyond opening/updating a PR still need human confirmation.

## Architecture Notes

Flake helpers:

- `lib.mk-nixos` builds full NixOS systems with overlays, sops-nix, impermanence, and common modules.
- `lib.mk-microvm` builds microVM guests with common modules.
- `lib.mk-incus-vm` and `lib.mk-incus-container` build Incus guests.
- Overlays expose custom packages as `pkgs.mmell.*` and shared helpers as `pkgs.mmell.lib.*`.

Network registry pattern:

```nix
net = pkgs.mmell.lib.data.network;
inherit (net.forHost "hostname") host zone;
```

Router zone model:

```nix
router6.zones.<name> = {
  icmpEcho = "enable" | "disable";
  accessTo = [ "other-zone" ];
  forwardRules.<target-zone> = [];
  inputRules = [];
};
```

Primary hosts:

- `thebeyond` - router, microVM host, impermanence, disko.
- `liberl` - NAS, ZFS/NFS, microVM host.
- `erebonia` - VM host for Incus/microVM/KubeVirt work.

## Testing Patterns

- Pass `system = "x86_64-linux"` explicitly in test configs; `builtins.currentSystem` is unavailable in pure flake eval.
- For forward-chain connectivity tests, use `ping` to avoid background listener process issues.
- Background processes in VM tests need redirected output: `cmd >/dev/null 2>&1 &`.
- Use `nc -z` for input-chain tests against running services.
- VM test machines should import `tests/lib/test-minimal-base.nix` to keep closures small.

## Secrets

Secrets are encrypted with sops-nix and age. Secret files live under `hosts/*/secrets/` and decrypt to `/run/secrets/`. Age keys live outside the repo in `.keys/` or operator secret storage. Never commit private keys or decrypted secrets.
