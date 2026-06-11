# NixOS homelab flake

This repository is the source of truth for a NixOS-based homelab: routers, VM hosts, microVM/Incus guests, OpenWrt device configuration, shared network data, deployment tooling, and the locked-down KubeVirt dev-machine used for agentic development.

Start here:

- [`AGENTS.md`](AGENTS.md) - model-neutral workflow for AI coding agents and operators working through the dev-machine.
- [`docs/`](docs/) - current operator-facing runbooks and architecture docs.
- [`llm-notes/`](llm-notes/) - plans, reports, specs, and historical implementation notes. Old plans are context, not source of truth.
- [`scripts/run-checks.sh`](scripts/run-checks.sh) - preferred full check runner. It runs flake checks in separate Nix processes to avoid `nix flake check` OOM behavior.
- [`scripts/agent-preflight.sh`](scripts/agent-preflight.sh) - quick/full validation entrypoint for agents.
- [`scripts/dev-machine-smoke.sh`](scripts/dev-machine-smoke.sh) - smoke test for the dev-machine runtime.

Common commands:

```bash
nix fmt
./scripts/agent-preflight.sh --quick
./scripts/run-checks.sh
nix build .#checks.x86_64-linux.<name>
```

Avoid running `nix flake check` directly for normal validation; this flake has enough NixOS evaluations that the single evaluator process can be OOM-killed. Use `./scripts/run-checks.sh` or targeted `nix build .#checks...` commands instead.
