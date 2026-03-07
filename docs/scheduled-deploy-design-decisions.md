# Scheduled Deploy Module - Design Decisions

This document explains key design decisions in the scheduled-deploy module.

## 1. Wrapper Flake in a Separate Git Repo

**Decision**: Each deployment target has a wrapper flake in its own git repository, separate from the main dotfiles flake.

**Problem**: A Nix flake has a single `flake.lock` — all outputs share the same pinned inputs. The router needs to update nixpkgs independently of the VM host, but there's no clean way to have different inputs for different outputs within one flake.

**Solution**: The wrapper flake lives in its own git repo (e.g., on the gitea server). It imports the dotfiles flake and re-exports its outputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    dotfiles.url = "git+ssh://git@10.0.100.31/var/lib/git/dotfiles.git";
    dotfiles.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = inputs: {
    inherit (inputs.dotfiles) nixosConfigurations deploy;
  };
}
```

**Result**: Each target gets an independent `flake.lock` via a real, source-controlled flake in its own repo. No dynamic flake generation.

## 2. Flakes Belong in Source Control

**Decision**: The wrapper flake is a durable artifact in a git repo, not a file generated at activation time.

**Why**: Flakes are designed to work with source control — that's why Nix has first-class `git+ssh://` support. Dynamically generating `flake.nix` files in `/var/lib/` is fragile, hard to audit, and goes against the grain of how flakes work. A git repo gives you:

- Version history of the flake definition
- Audit trail of every `flake.lock` update (via commits)
- Deployment history (via tags)
- Durability independent of any single machine

## 3. The VM Host Owns the Full Update Pipeline

**Decision**: The module handles the entire workflow — pull, update inputs, commit, push, deploy — rather than splitting responsibilities across machines.

**Why**: The goal is automated weekly updates. Splitting "update inputs" and "deploy" across different machines or timers creates coordination complexity and doesn't actually solve the problem end-to-end. The module owns:

1. `git pull` — get latest wrapper flake definition
2. `nix flake update` — update nixpkgs and dotfiles inputs
3. `git commit && git push` — record the update in source control
4. `deploy .#node` — build locally, deploy with rollback

The router is purely a deployment target. It doesn't manage its own updates.

## 4. Git Tags for Deployment History

**Decision**: Tag the repo after each successful deployment with `deploy/<node>/<timestamp>`.

**Why**: Commits record input updates, but not whether the deployment succeeded. A tag after `deploy` succeeds tells you exactly what was deployed and when. You can:

- `git log --tags` to see deployment timeline
- `git diff deploy/thebeyond/20260215.. deploy/thebeyond/20260222..` to see what changed between deployments
- Quickly identify the last successful deployment

Tags are only created after deploy-rs succeeds, so they represent actual deployments, not attempts.

## 5. Individual Systemd Units

**Decision**: Generate individual `scheduled-deploy-<node>` services instead of using systemd template units.

**Why**: Simpler to understand, debug, and extend. For 1-2 deployment targets, templates add indirection without benefit. Each unit's configuration is fully visible in `systemctl cat`.

## 6. Simplified Per-Node Options

**Decision**: Each node has `schedule`, `flakeRef`, and `deployNode` — nothing else.

**Why**: The previous module had `skipChecks`, `extraDeployArgs`, `defaults`, `updateInputs` — none of which were used. The wrapper flake pattern makes `updateInputs` inherent to the workflow. deploy-rs configuration (checks, rollback, etc.) belongs in the flake's deploy output, not in the scheduler.

## Summary

1. **Source-controlled**: Wrapper flakes live in real git repos
2. **End-to-end**: The module handles update + deploy as one pipeline
3. **Auditable**: Git commits track input updates, tags track deployments
4. **Simple**: Minimal options, individual units, no unused features
5. **Decoupled**: Independent `flake.lock` per target via separate repos
