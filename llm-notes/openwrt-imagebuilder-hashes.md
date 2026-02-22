# OpenWrt ImageBuilder Hash Instability

## Problem

`nix-openwrt-imagebuilder` (github:astro/nix-openwrt-imagebuilder) pins hashes of
mutable files on `downloads.openwrt.org` — `sha256sums` and `Packages` index files
that change whenever OpenWrt rebuilds packages for a release. The upstream CI
regenerates these hashes daily, but the GitHub Action is flaky and frequently fails,
leaving stale hashes that break builds.

## Workaround

The project provides a local hash regeneration tool:

```bash
# Inside a clone of nix-openwrt-imagebuilder:
nix run .#release2nix -- $(nix run .#list-versions -- -l)
```

This fetches fresh files from `downloads.openwrt.org` and updates all cache hashes.
After committing the result, point the flake input at the updated clone/fork.

This is scriptable — could be wrapped as a flake app (e.g. `nix run .#openwrt-update-hashes`)
that automates: pull, regenerate, commit, `nix flake update`.

## Decision

Deferred — how we manage this fork/clone ties into the broader question of how we
handle git dependencies. Revisit when that approach is settled.

## Status

As of 2026-02-22, the upstream CI has been failing since ~Feb 12. Builds of OpenWrt
images (`nix build .#openwrtImages.<device>`) fail with hash mismatches. The UCI
config generation and evaluation work fine — only the final image build step is affected.
