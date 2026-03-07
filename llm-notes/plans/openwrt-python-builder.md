# Replace nix-openwrt-imagebuilder with Custom Python Builder

## Context

The current OpenWrt image build pipeline uses `nix-openwrt-imagebuilder` (a third-party flake) to produce firmware images. This has three major pain points:

1. **Hash instability**: The flake pins SHA256 hashes of mutable upstream files (`Packages` indexes on `downloads.openwrt.org`). Upstream CI regenerates daily but is flaky — builds have been broken since ~Feb 12 2026.
2. **Nix store exposure**: Built images land in the world-readable nix store, so WiFi secrets can't be baked in. This forces a fragile two-phase deploy: flash image with disabled radios, then push secrets via SSH.
3. **Maintenance overhead**: Requires a local clone of `nix-openwrt-imagebuilder` at `temp/` just for hash regeneration.

The replacement: a Python script that downloads the upstream OpenWrt Image Builder tarball directly, prepares filesystem overlays (with secrets baked in), and runs `make image`. Output goes to a local directory, never the nix store. All existing Nix UCI config generation (~1000 lines, 70+ tests) is preserved.

## Architecture

```
Nix (config generation - UNCHANGED)      Python (image building - NEW)
┌────────────────────────────────┐       ┌──────────────────────────────┐
│ Device declarations (.nix)     │       │ 1. nix eval --json           │
│ lib/openwrt/ (UCI generation)  │──────>│    .#openwrtBuildInfo.<dev>  │
│ openwrtBuildInfo (new output)  │       │ 2. sops -d wifi.yaml         │
└────────────────────────────────┘       │ 3. Merge secrets into UCI    │
                                         │ 4. Download Image Builder    │
                                         │ 5. make image                │
                                         │ 6. Output → ./openwrt-images/│
                                         └──────────────────────────────┘
```

---

## Phase 1: Nix-side Preparation (non-breaking)

### 1.1 Add `target`/`subtarget` to device declarations

Add two fields to each device file in `hosts/openwrt/`:

| Device file                                                                                             | target     | subtarget |
| ------------------------------------------------------------------------------------------------------- | ---------- | --------- |
| `bobcat.nix`, `lusitania.nix`, `merkabah.nix`, `derfflinger.nix`, `pantagruel.nix`, `bobcat-router.nix` | `mediatek` | `mt7622`  |
| `arseille.nix`                                                                                          | `realtek`  | `rtl838x` |
| `glorious.nix`                                                                                          | `ramips`   | `mt7621`  |

### 1.2 Export `migrationPreCommands` from `lib/openwrt/default.nix`

Currently a `let` binding (line ~817). Add to the return attrset (line ~983) so `openwrtBuildInfo` can reference it.

### 1.3 Add `openwrtBuildInfo` flake output

New output in `flake.nix` (after `openwrtConfigs`). For each device, produces a JSON-serializable attrset:

```nix
openwrtBuildInfo = let
  owrtData = import ./lib/common/data/openwrt.nix { inherit (nixpkgs) lib; };
  openwrt = self.lib.openwrt;
in builtins.mapAttrs (name: device:
  let
    config = openwrt.mkDeviceConfig { inherit device owrtData; };
    packages = <select by device.type, same logic as mkDeviceImage>;
  in {
    hostname = device.hostname;
    profile = device.profile;
    target = device.target;
    subtarget = device.subtarget;
    release = device.release or owrtData.defaultRelease;
    inherit packages;
    uciDefaultsScript = openwrt.uci.mkUCIDefaults {
      name = "nix-config";
      inherit config;
      preCommands = openwrt.migrationPreCommands;
    };
    secretsApplyScript = openwrt.mkSecretsApplyScript { inherit device owrtData; };
    secretsMap = openwrt.mkSecretsMap { inherit device owrtData; };
    authorizedKeys = owrtData.authorizedKeys;
    deviceType = device.type;
  }
) self.openwrtDevices;
```

### 1.4 Update tests (`tests/lib/openwrt-config.nix`)

- Assert `target`/`subtarget` present on all real devices
- Assert `migrationPreCommands` is exported and is a list
- Assert buildInfo structure validates (hostname, target, subtarget, release, packages, uciDefaultsScript are correct types)

### 1.5 Verify

```bash
nix flake check --print-build-logs
nix eval --json .#openwrtBuildInfo.bobcat | python3 -m json.tool  # inspect output
```

---

## Phase 2: Python Builder (additive)

### 2.1 Write `apps/openwrt/build.py` (~300 lines)

Single Python file with these functions:

- **`get_build_info(device, repo_root)`** — runs `nix eval --json .#openwrtBuildInfo.<device>`, returns dict
- **`decrypt_secrets(secrets_file)`** — runs `sops -d`, parses YAML to flat key=value dict via `yq`
- **`merge_secrets_into_uci(uci_script, secrets_map, secrets_kv, device_type)`** — inserts `uci set` commands for each secret before the `uci commit` line; enables radios for WiFi devices
- **`download_imagebuilder(release, target, subtarget, cache_dir)`** — downloads tarball from `https://downloads.openwrt.org/releases/{release}/targets/{target}/{subtarget}/openwrt-imagebuilder-{release}-{target}-{subtarget}.Linux-x86_64.tar.zst`, extracts, returns path. Caches in `~/.cache/openwrt-builder/`.
- **`prepare_files(build_info, uci_script, tmpdir)`** — creates FILES directory: `etc/uci-defaults/99-nix-config`, `etc/dropbear/authorized_keys`, `etc/nix-secrets-apply` (kept for runtime use)
- **`build_image(ib_dir, profile, packages, files_dir, output_dir)`** — runs `make image PROFILE=... PACKAGES="..." FILES=... BIN_DIR=...`
- **`find_sysupgrade(output_dir)`** — locates `*-sysupgrade.bin` or `*.img.gz`
- **`main()`** — argparse CLI: `openwrt-build <device> [--no-secrets] [--output-dir DIR] [--cache-dir DIR]`

Key design decisions:

- Standard library only (no pip dependencies). Uses `subprocess` for sops/nix/make, `json` for parsing, `pathlib` for paths.
- Temp directory with restricted permissions (0o700) for secrets; cleaned up in `finally` block.
- Default output: `./openwrt-images/<device>/`
- `--no-secrets` flag for building without WiFi credentials (testing/no sops key)

### 2.2 Add `openwrt-build` flake app wrapper

In `apps/openwrt/default.nix`, add a new app that wraps `build.py` with required tools in PATH:

```nix
openwrt-build = {
  type = "app";
  program = "${pkgs.writeShellScript "openwrt-build" ''
    export PATH="${lib.makeBinPath [
      pkgs.python3 pkgs.sops pkgs.yq-go pkgs.nix pkgs.git
      pkgs.gnumake pkgs.gnutar pkgs.zstd pkgs.wget pkgs.coreutils
      pkgs.findutils pkgs.gnugrep pkgs.gawk pkgs.gnused pkgs.perl
      pkgs.patch pkgs.diffutils pkgs.file pkgs.unzip pkgs.bzip2
      pkgs.which pkgs.ncurses pkgs.rsync pkgs.xz
    ]}:$PATH"
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    exec python3 "$REPO_ROOT/apps/openwrt/build.py" "$@"
  ''}";
};
```

Wire in `apps/default.nix`.

### 2.3 Add `openwrt-images/` to `.gitignore`

Already has `temp/` ignored. Add `openwrt-images/` — these are binary artifacts containing secrets.

### 2.4 Manual test

```bash
nix run .#openwrt-build -- bobcat
ls -la openwrt-images/bobcat/
```

---

## Phase 3: Deploy Integration

### 3.1 Update `openwrt-deploy`

In `apps/openwrt/default.nix`, update the deploy script:

**Before:** `nix build .#openwrtImages.$DEVICE` -> find in nix store -> SCP -> sysupgrade -> wait -> SSH secrets
**After:** `nix run .#openwrt-build -- $DEVICE` -> find in `./openwrt-images/$DEVICE/` -> SCP -> sysupgrade -> done

Remove the post-deploy secrets step entirely. The image is self-contained.

Keep `--skip-secrets` as `--no-secrets` (passed through to the builder for testing).

### 3.2 Keep `openwrt-configure-secrets` as-is

Still useful for changing WiFi passwords on running devices without reflashing. The `nix-secrets-apply` script is still baked into images for this use case.

### 3.3 Update `openwrt-show-config`

Change from evaluating via derivation to:

```bash
nix eval --raw ".#openwrtBuildInfo.$DEVICE.uciDefaultsScript"
```

---

## Phase 4: Cleanup (separate commit)

### 4.1 Make `openwrt-imagebuilder` optional in `lib/openwrt/default.nix`

Change signature to `{ lib, openwrt-imagebuilder ? null }:`. Guard `mkImage`/`mkDeviceImage` to throw if called without it.

### 4.2 Remove flake dependency

- Remove `openwrt-imagebuilder` from `flake.nix` inputs
- Remove `openwrtImages` output
- Update `lib.openwrt` construction to not pass `openwrt-imagebuilder`
- Run `nix flake lock --remove-input openwrt-imagebuilder`

### 4.3 Remove `openwrt-profiles` app

Or rewrite to fetch `profiles.json` from upstream directly (deferred — low priority).

### 4.4 Update documentation

- `hosts/openwrt/default.nix` header comments
- `apps/openwrt/default.nix` header comments
- `CLAUDE.md` build commands section
- `llm-notes/openwrt-imagebuilder-hashes.md` — mark as resolved

---

## Files Modified

| File                              | Change                                                                           |
| --------------------------------- | -------------------------------------------------------------------------------- |
| `hosts/openwrt/bobcat.nix`        | Add `target`/`subtarget`                                                         |
| `hosts/openwrt/lusitania.nix`     | Add `target`/`subtarget`                                                         |
| `hosts/openwrt/merkabah.nix`      | Add `target`/`subtarget`                                                         |
| `hosts/openwrt/derfflinger.nix`   | Add `target`/`subtarget`                                                         |
| `hosts/openwrt/pantagruel.nix`    | Add `target`/`subtarget`                                                         |
| `hosts/openwrt/bobcat-router.nix` | Add `target`/`subtarget`                                                         |
| `hosts/openwrt/arseille.nix`      | Add `target`/`subtarget`                                                         |
| `hosts/openwrt/glorious.nix`      | Add `target`/`subtarget`                                                         |
| `lib/openwrt/default.nix`         | Export `migrationPreCommands`; make `openwrt-imagebuilder` optional              |
| `flake.nix`                       | Add `openwrtBuildInfo` output; remove `openwrtImages` + input                    |
| `apps/openwrt/build.py`           | **NEW** — Python image builder                                                   |
| `apps/openwrt/default.nix`        | Add `openwrt-build` app; update `openwrt-deploy`, `openwrt-show-config`          |
| `apps/default.nix`                | Wire `openwrt-build`                                                             |
| `tests/lib/openwrt-config.nix`    | Add tests for target/subtarget, migrationPreCommands export, buildInfo structure |
| `.gitignore`                      | Add `openwrt-images/`                                                            |
| `hosts/openwrt/default.nix`       | Update header comments                                                           |
| `CLAUDE.md`                       | Update build commands                                                            |

## Verification

1. **Phase 1**: `nix flake check --print-build-logs` — all existing tests pass, new tests pass
2. **Phase 2**: `nix run .#openwrt-build -- bobcat` — produces sysupgrade image in `./openwrt-images/bobcat/`
3. **Phase 2**: `nix run .#openwrt-build -- bobcat --no-secrets` — builds without secrets
4. **Phase 3**: `nix run .#openwrt-deploy -- bobcat 10.0.10.23` — builds + flashes (test on actual hardware)
5. **Phase 4**: `nix flake check --print-build-logs` after removing `openwrt-imagebuilder` input
