# Pin OpenWrt Image Builder to Nix Store

## Context

The Python builder previously downloaded the upstream OpenWrt Image Builder tarball to
`~/.cache/openwrt-builder/` at build time. This had two weaknesses:

1. **No GC-root protection**: `openwrtConfigurations` derivations didn't pull the Image
   Builder into their closure, so rebuilding later wasn't guaranteed to work.
2. **Non-deterministic**: If OpenWrt republished or removed a release tarball, builds
   could break or silently change.

This feature pins each Image Builder tarball as a `pkgs.fetchurl` derivation in the Nix
store, with its store path recorded in the device's `build.json` manifest.

## Final Architecture

```
openwrtConfigurations.<device>  →  build.json (flat manifest)
                                       ├── uciDefaults:         /nix/store/...-uci-defaults-<device>.sh
                                       ├── secretsApply:        /nix/store/...-secrets-apply-<device>.sh
                                       ├── authorizedKeys:      /nix/store/...-authorized-keys        ← shared across all devices
                                       └── imageBuilderTarball: /nix/store/...-openwrt-imagebuilder-<release>-<target>.tar.zst

openwrt-build <device>
  └── extract imagebuilder from store path (cached in ~/.cache/openwrt-builder/)
  └── make image
```

`build.json` is a flat manifest — all values are file paths (absolute when produced by
Nix, but the tool accepts relative paths too for hand-crafted manifests). There is no
nested structure.

## Key Design Decisions

**Manifest-driven, not directory-driven.** `openwrtConfigurations` outputs contain only
`build.json`. All referenced files (UCI script, secrets-apply, authorized_keys) are
independent Nix store entries referenced by absolute path. This gives natural
deduplication: `authorized_keys` is identical across all devices and produces a single
shared store entry.

**Flat manifest.** `build.json` has no nested keys. All fields — including file paths —
are at the top level. This avoids indirection and makes the format easier to read and
hand-edit.

**Hashes in JSON, code in Nix.** Image Builder hashes and `defaultRelease` live in
`lib/common/data/openwrt-hashes.json`, not in the Nix source. The `--update-pins`
command writes only to that file, with no regex manipulation of Nix code.

**`--update-pins` is a two-phase orchestration.** The build wrapper fetches hashes and
writes `openwrt-hashes.json`, then re-evaluates `nix build .#openwrtConfigurations.<device>`
to pick up the new hash before building. This mirrors how `nix flake update` works.

## Files

| File | Role |
|---|---|
| `lib/common/data/openwrt-hashes.json` | `defaultRelease` + `imageBuilderHashes` registry; updated by `--update-pins` |
| `lib/common/data/openwrt.nix` | Reads pins from JSON; exposes `defaultRelease` and `imageBuilderHashes` as Nix values |
| `flake.nix` (`openwrtConfigurations`) | `mkImageBuilderFetcher` helper; assembles flat `build.json` with store paths |
| `lib/openwrt/default.nix` (`mkConfigFiles`) | Produces per-device store files; `authorized-keys` named without hostname for dedup |
| `packages/openwrt-builder/build.py` | Reads flat manifest; extracts imagebuilder from store path when available |
| `apps/openwrt/default.nix` | Shell wrapper; parses `--update`/`--update-pins`/`--release`; passes `--config-file "$CONFIG_DIR/build.json"` |

## Device → Image Builder Mapping

All current devices map to three unique `(release, target, subtarget)` tuples:

| Devices | target | subtarget |
|---|---|---|
| bobcat, lusitania, merkabah, derfflinger, pantagruel, bobcat-router | mediatek | mt7622 |
| arseille | realtek | rtl838x |
| glorious | ramips | mt7621 |

## Workflows

```bash
# Build (uses pinned imagebuilder from store, or downloads if not pinned)
nix run .#openwrt-build -- <device>

# Update hashes for all targets, then exit
nix run .#openwrt-build -- --update-pins

# Update hashes for one device's target, then exit
nix run .#openwrt-build -- <device> --update-pins

# Update hashes and immediately build
nix run .#openwrt-build -- <device> --update

# Manual two-step pipeline
CONFIG_DIR=$(nix build .#openwrtConfigurations.<device> --print-out-paths --no-link)
nix run .#openwrt-build -- --config-file "$CONFIG_DIR/build.json" [--secrets-file ...]
```

## Update Flow Detail

```
openwrt-build <device> --update
  │
  ├─[Phase 1: Update hashes]
  │   ├── Query latest stable release from downloads.openwrt.org
  │   ├── For each target: nix store prefetch-file → SRI hash (warms store)
  │   ├── Write updated defaultRelease + hashes to openwrt-hashes.json
  │   └── (source file on disk is now updated)
  │
  └─[Phase 2: Build]
      ├── nix build .#openwrtConfigurations.<device>  (picks up new hash)
      ├── Extract ImageBuilder from Nix store path (cached in ~/.cache/)
      └── make image
```

## Rollback

Pinning the imagebuilder provides **builder reproducibility** — the same imagebuilder
binary is used. It does not guarantee full image reproducibility because the imagebuilder
pulls packages from OpenWrt's own feeds at build time.

The practical rollback story is keeping the built `.bin` files. See Future Goals below.

## Future Goals

### Image archiving in the deployment pipeline

A future `openwrt-deploy` iteration should archive the `.bin` sysupgrade image alongside
its `build.json` snapshot (e.g. in `openwrt-images/archive/<device>/<timestamp>/`)
before deploying. This gives a concrete artifact to roll back to: the exact image that
was flashed, paired with the manifest that describes how it was built.

The image builder tool places output in `openwrt-images/<device>/` and exits. Archiving
is the deployer's responsibility, not the builder's.
