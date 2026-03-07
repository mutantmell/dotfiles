# OpenWrt Config Build Artifact Refactor

## Context

The OpenWrt build system currently serializes all device config into a monolithic JSON blob at Nix eval time (`openwrtBuildInfo` → `pkgs.writeText` → `--build-info` flag to Python builder). This is a bespoke data-passing mechanism that doesn't produce inspectable build artifacts and doesn't integrate with standard Nix tooling (caching, CI, `nix build`).

This refactor replaces that with per-device Nix store files using `builtins.toFile` (system-independent, no `pkgs` needed). Each device gets a `build.json` metadata file that references separate UCI script, secrets-apply script, and authorized_keys files via absolute store paths. The Python builder consumes these files instead of the monolithic JSON blob.

A new top-level `openwrtConfigurations` flake output (similar to `nixosConfigurations`) provides `nix build`-able config artifacts per device.

**Strict requirement:** No secrets in any store file.

## Files to Modify

| File                                | Change                                                                            |
| ----------------------------------- | --------------------------------------------------------------------------------- |
| `lib/openwrt/default.nix`           | Add `mkConfigFiles` function                                                      |
| `flake.nix`                         | Remove `openwrtBuildInfo`, add `openwrtConfigurations` output, update `apps` call |
| `apps/default.nix`                  | Change function signature                                                         |
| `apps/openwrt/default.nix`          | Replace JSON blob with per-device file lookup table                               |
| `packages/openwrt-builder/build.py` | Replace `--build-info` with `--config-file`, load JSON + referenced files         |
| `tests/lib/openwrt-config.nix`      | Add config file tests (pure eval using `builtins.readFile`)                       |
| `CLAUDE.md`                         | Document `nix build .#openwrtConfigurations.<device>`                             |

## Step 1: Add `mkConfigFiles` to `lib/openwrt/default.nix`

Add a function `mkConfigFiles = { device, owrtData }: { ... }` that returns an attrset of store file paths. Uses only `builtins.toFile` — no `pkgs` needed, fully system-independent.

Package selection logic (meshAP→`defaultMeshPackages`, etc.) moves from `flake.nix:openwrtBuildInfo` into this function.

**Return value:**

```nix
{
  configJson = builtins.toFile "openwrt-config-<hostname>.json" (builtins.toJSON {
    hostname = "bobcat";
    profile = "linksys_e8450-ubi";
    target = "mediatek";
    subtarget = "mt7622";
    release = "24.10.5";
    deviceType = "meshAP";
    packages = [ "-dnsmasq" "kmod-batman-adv" ... ];
    secretsMap = { "mesh_id" = [ "wireless.batmesh.mesh_id" ]; ... };
    files = {
      uciDefaults = "/nix/store/...-uci-defaults-bobcat.sh";
      secretsApply = "/nix/store/...-secrets-apply-bobcat.sh";
      authorizedKeys = "/nix/store/...-authorized-keys-bobcat";
    };
  });
  uciFile = builtins.toFile "uci-defaults-<hostname>.sh" uciScript;
  secretsFile = builtins.toFile "secrets-apply-<hostname>.sh" secretsApplyScript;
  keysFile = builtins.toFile "authorized-keys-<hostname>" keysContent;
}
```

The `configJson` references the other files via their store paths in the `files` field. `builtins.toFile` tracks these as dependencies automatically.

Export `mkConfigFiles` alongside the existing API.

## Step 2: Add `openwrtConfigurations` and update `flake.nix`

**Remove** `openwrtBuildInfo` (lines 248-279) — no external consumers.

**Add `openwrtConfigurations`** — top-level system-independent attrset (like `nixosConfigurations`):

```nix
openwrtConfigurations = let
  owrtData = import ./lib/common/data/openwrt.nix { inherit (nixpkgs) lib; };
in builtins.mapAttrs (_: device:
  (self.lib.openwrt.mkConfigFiles { inherit device owrtData; }).configJson
) self.openwrtDevices;
```

This enables `nix build .#openwrtConfigurations.bobcat` → produces a JSON file in the store.

**Update `apps` call** — compute device file sets and pass to apps:

```nix
apps = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: let
  pkgs = pkgsFor nixpkgs system;
  owrtData = import ./lib/common/data/openwrt.nix { inherit (nixpkgs) lib; };
  openwrtDeviceFiles = builtins.mapAttrs (_: device:
    self.lib.openwrt.mkConfigFiles { inherit device owrtData; }
  ) self.openwrtDevices;
in import ./apps {
  inherit pkgs;
  openwrtDevices = self.openwrtDevices;
  inherit openwrtDeviceFiles;
});
```

Due to `builtins.toFile` content-addressing, the store paths from `openwrtConfigurations` and `apps` are identical — no duplication.

## Step 3: Update app wrappers

### `apps/default.nix`

Change signature from `{ pkgs, openwrtBuildInfo }` to `{ pkgs, openwrtDevices, openwrtDeviceFiles }`.

### `apps/openwrt/default.nix`

Signature: `{ pkgs, openwrtDevices, openwrtDeviceFiles }`.

**Remove** `buildInfoFile` (the `pkgs.writeText` JSON blob).

**Add device lookup** — shell `case` statements generated at eval time mapping device names to store paths. Two lookup tables: one for the config JSON (Python builder), one for the UCI file (show-config):

```nix
deviceConfigLookup = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: files:
  "  ${name}) CONFIG_FILE=\"${files.configJson}\" ;;"
) openwrtDeviceFiles);

deviceUciLookup = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: files:
  "  ${name}) UCI_FILE=\"${files.uciFile}\" ;;"
) openwrtDeviceFiles);
```

**`openwrt-build`**: Resolves device name → config JSON via lookup, discovers secrets, calls `openwrt-build --config-file "$CONFIG_FILE" $SECRETS_ARGS "$@"`. The `--list-devices` flag is handled in the wrapper using device metadata embedded at eval time.

**`openwrt-show-config`**: Pure shell — resolves device → UCI file path via lookup, `cat "$UCI_FILE"`. No Python.

**`openwrt-deploy`**: Same pattern — resolve config file, pass to builder, then deploy.

**Unchanged apps**: `openwrt-configure-secrets`, `openwrt-export-config`, `openwrt-analyze-packages`, `openwrt-analyze-local` don't use build info.

## Step 4: Update Python builder (`build.py`)

**Replace `--build-info` with `--config-file`** (path to JSON config file). New loading logic:

```python
def load_config(config_file):
    """Load build config from a Nix-generated JSON config file."""
    with open(config_file) as f:
        meta = json.load(f)
    # Read referenced files (absolute Nix store paths in meta["files"])
    files = meta["files"]
    meta["uciDefaultsScript"] = Path(files["uciDefaults"]).read_text()
    meta["secretsApplyScript"] = Path(files["secretsApply"]).read_text()
    keys_content = Path(files["authorizedKeys"]).read_text()
    meta["authorizedKeys"] = [k for k in keys_content.splitlines() if k.strip()]
    return meta
```

**Remove**: `load_build_info_from_file()`, `get_build_info()`, `list_devices()`, `--show-config`, `--list-devices`, `device` positional arg.

**Keep unchanged**: `flatten_yaml()`, `decrypt_secrets()`, `escape_uci_value()`, `merge_secrets_into_uci()`, `extract_tar_zst()`, `download_imagebuilder()`, `build_image()`, `find_sysupgrade()`.

**Update `prepare_files()`**: Read authorized_keys and secrets-apply from the store paths referenced in the config, not from inline JSON strings.

Output dir default changes from `./openwrt-images/<device>/` to `./openwrt-images/<hostname>/` (hostname comes from config JSON). Or the wrapper passes `--output-dir` explicitly.

## Step 5: Update tests (`tests/lib/openwrt-config.nix`)

Existing pure-eval tests (config structure, UCI rendering, secrets map) remain unchanged.

**Add pure-eval tests for `mkConfigFiles`** using `builtins.readFile`:

```nix
meshFiles = openwrt.mkConfigFiles { device = meshDevice; inherit owrtData; };
meshMeta = builtins.fromJSON (builtins.readFile meshFiles.configJson);
meshUci = builtins.readFile meshFiles.uciFile;
```

Test assertions:

- `meshMeta.hostname == "test-mesh"`
- `meshMeta.deviceType == "meshAP"`
- `meshMeta ? profile && meshMeta ? target && meshMeta ? packages`
- `meshMeta ? secretsMap`
- `meshMeta ? files && meshMeta.files ? uciDefaults`
- `builtins.match ".*test-mesh.*" meshUci != null` (hostname in UCI)
- `builtins.match ".*(secret|password).*" meshUci == null` (no secrets in UCI)
- Same for switch, simpleAP, router device types
- All real devices produce valid `mkConfigFiles` output

These are all pure eval — no `pkgs` needed, fast.

**Remove** any tests that verify `openwrtBuildInfo` structure.

## Step 6: Update CLAUDE.md

Add:

```
# Build an OpenWrt config (pure Nix, no secrets, no network)
nix build .#openwrtConfigurations.<device-name>
```

## Verification

1. `nix build .#openwrtConfigurations.bobcat` — produces a JSON file in the store
2. `cat $(nix build .#openwrtConfigurations.bobcat --print-out-paths)` — JSON with file references
3. `nix run .#openwrt-show-config -- bobcat` — shows UCI config directly
4. `nix run .#openwrt-build -- --list-devices` — lists all devices
5. `nix run .#openwrt-build -- bobcat --no-secrets` — full image build
6. `nix-instantiate --eval --strict tests/lib/openwrt-config.nix` — pure eval tests pass
7. `nix build .#checks.x86_64-linux.openwrt-config` — check passes
8. `nix flake check --print-build-logs` — all checks pass
