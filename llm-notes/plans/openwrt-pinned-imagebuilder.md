# Pin OpenWrt Image Builder to Nix Store

## Context

The current Python builder downloads the upstream OpenWrt Image Builder tarball to
`~/.cache/openwrt-builder/` at build time. This is fine for normal use, but has two
weaknesses:

1. **No GC-root protection**: `openwrtConfigurations` derivations don't pull the Image
   Builder into their closure, so "add config as GC root → rebuild later" doesn't
   guarantee you can still build.
2. **Non-deterministic**: If OpenWrt republishes a release tarball (or removes it),
   builds may break or silently change.

This plan adds `pkgs.fetchurl` derivations for each Image Builder tarball and embeds
the store path in each device's `build.json`. The Python builder uses the Nix store
tarball directly instead of downloading.

## Architecture

```
Before:
  openwrtConfigurations.bobcat  →  build.json (config only)
  openwrt-build bobcat          →  download tarball  →  extract  →  make image

After:
  openwrtConfigurations.bobcat  →  build.json (config + imageBuilderTarball path)
                                        │
                                        └→  pkgs.fetchurl(.../openwrt-imagebuilder-24.10.5-mediatek-mt7622.tar.zst)
  openwrt-build bobcat          →  extract from store path  →  make image
                                   (cache extraction in ~/.cache/openwrt-builder/)
```

## Device → Image Builder mapping

All current devices map to three unique `(release, target, subtarget)` tuples. The
same fetchurl derivation is shared by all devices with the same target:

| Devices | target | subtarget |
|---|---|---|
| bobcat, lusitania, merkabah, derfflinger, pantagruel, bobcat-router | mediatek | mt7622 |
| arseille | realtek | rtl838x |
| glorious | ramips | mt7621 |

## Files to Modify

| File | Change |
|---|---|
| `lib/common/data/openwrt.nix` | Add `imageBuilderHashes` registry |
| `flake.nix` | Add `mkImageBuilderFetcher` helper; embed `imageBuilderTarball` in `openwrtConfigurations` |
| `packages/openwrt-builder/build.py` | Use store path tarball when available; update `download_imagebuilder`; add update flow |
| `apps/openwrt/default.nix` | Add `--update` / `--update-pins` flags to `openwrt-build` wrapper; remove standalone `openwrt-prefetch-imagebuilder` app (folded into build) |
| `CLAUDE.md` | Document hash update workflow |

---

## Step 1: Add hash registry to `lib/common/data/openwrt.nix`

Add a new `imageBuilderHashes` attrset at the top level. Keys are release version, then
`"<target>/<subtarget>"`:

```nix
# SHA-256 hashes for OpenWrt Image Builder tarballs, keyed by release and target.
# Tarballs are downloaded from:
#   https://downloads.openwrt.org/releases/<release>/targets/<target>/<subtarget>/
#   openwrt-imagebuilder-<release>-<target>-<subtarget>.Linux-x86_64.tar.zst
#
# To update hashes for a new release, run:
#   nix run .#openwrt-prefetch-imagebuilder -- <release> <target> <subtarget>
#
imageBuilderHashes = {
  "24.10.5" = {
    "mediatek/mt7622"  = "sha256-<hash>";
    "realtek/rtl838x"  = "sha256-<hash>";
    "ramips/mt7621"    = "sha256-<hash>";
  };
};
```

The actual hashes need to be computed (see Step 5). Placeholders above.

---

## Step 2: Add `mkImageBuilderFetcher` in `flake.nix`

Within the `openwrtConfigurations` let-block (which already binds `pkgs`), add a helper
that produces a `pkgs.fetchurl` derivation for a given device:

```nix
openwrtConfigurations = let
  pkgs = pkgsFor nixpkgs "x86_64-linux";
  owrtData = import ./lib/common/data/openwrt.nix { inherit (nixpkgs) lib; };

  # Produce a fetchurl derivation for the Image Builder tarball.
  # Returns null if the hash is not in the registry.
  mkImageBuilderFetcher = device:
    let
      release = device.release or owrtData.defaultRelease;
      targetKey = "${device.target}/${device.subtarget}";
      hashes = owrtData.imageBuilderHashes.${release} or {};
      hash = hashes.${targetKey} or null;
      ibName = "openwrt-imagebuilder-${release}-${device.target}-${device.subtarget}.Linux-x86_64";
    in
    if hash == null then null
    else pkgs.fetchurl {
      name = "${ibName}.tar.zst";
      url = "https://downloads.openwrt.org/releases/${release}/targets/${device.target}/${device.subtarget}/${ibName}.tar.zst";
      inherit hash;
    };

in builtins.mapAttrs (_: device:
  let
    files = self.lib.openwrt.mkConfigFiles { inherit device owrtData; };
    ibTarball = mkImageBuilderFetcher device;
    release = device.release or owrtData.defaultRelease;
  in pkgs.runCommand "openwrt-config-${device.hostname}" {} ''
    mkdir -p $out
    cp ${files.uciFile} $out/uci-defaults.sh
    cp ${files.secretsFile} $out/secrets-apply.sh
    cp ${files.keysFile} $out/authorized_keys
    cat > $out/build.json <<'EOF'
    ${builtins.toJSON ({
      hostname = device.hostname;
      profile = device.profile;
      target = device.target;
      subtarget = device.subtarget;
      release = release;
      deviceType = device.type;
      packages = self.lib.openwrt.packagesForDevice device;
      secretsMap = self.lib.openwrt.mkSecretsMap { inherit device owrtData; };
      files = {
        uciDefaults = "./uci-defaults.sh";
        secretsApply = "./secrets-apply.sh";
        authorizedKeys = "./authorized_keys";
      };
    } // (if ibTarball != null then { imageBuilderTarball = "${ibTarball}"; } else {}))}
    EOF
  ''
) self.openwrtDevices;
```

Key design decisions:
- `ibTarball = null` if hash not in registry → `imageBuilderTarball` is omitted from
  `build.json`. Python builder falls back to downloading (backwards compatible).
- The `${ibTarball}` interpolation in the runCommand script adds `ibTarball` to the
  derivation's input closure automatically. Nix tracks this dependency even though the
  tarball path only appears inside the JSON string.
- All devices sharing a target get the **same** `pkgs.fetchurl` derivation
  (content-addressed → same store path).

**Important note on closure tracking:** Nix will NOT automatically track the imagebuilder
derivation as part of the closure just because its path appears as a string in `build.json`.
To properly include it in the closure, the `runCommand` derivation needs to reference
`ibTarball` directly. One approach: create a symlink or zero-byte sentinel file:

```nix
pkgs.runCommand "openwrt-config-${device.hostname}"
  { imageBuilder = ibTarball; }  # ← adds ibTarball to inputDrvs
  ''
    mkdir -p $out
    # ... copy files, write build.json ...
    # Record the store path in a separate file (symlinks not allowed in store)
    ${if ibTarball != null then ''echo "${ibTarball}" > $out/imagebuilder-path'' else ""}
  ''
```

Then Python builder reads `imagebuilder-path` from the config directory, not from
`build.json`. This keeps `build.json` clean and ensures the dependency is tracked.

**Revised approach (simpler):** Put `imageBuilderTarball` in both:
1. `$out/imagebuilder-path` — a plain text file containing the store path
2. The `runCommand` environment (`{ imageBuilder = ibTarball; }`) — ensures Nix closure

This is the correct way. Update `build.json` reader in Python to also check for
`imagebuilder-path` file alongside `build.json`.

---

## Step 3: Update Python builder (`build.py`)

Modify `load_config_dir` and `download_imagebuilder` to handle the pinned tarball case.

### 3.1 `load_config_dir` — read `imagebuilder-path` file

```python
def load_config_dir(config_dir):
    config_dir = Path(config_dir)
    with open(config_dir / "build.json") as f:
        meta = json.load(f)

    files = meta.pop("files")
    base = config_dir
    meta["uciDefaultsScript"] = (base / files["uciDefaults"]).read_text()
    meta["secretsApplyScript"] = (base / files["secretsApply"]).read_text()
    keys_content = (base / files["authorizedKeys"]).read_text()
    meta["authorizedKeys"] = [k for k in keys_content.splitlines() if k.strip()]

    # Load pinned Image Builder tarball path if available
    ib_path_file = config_dir / "imagebuilder-path"
    if ib_path_file.exists():
        meta["imageBuilderTarball"] = ib_path_file.read_text().strip()

    return meta
```

### 3.2 `download_imagebuilder` — extract from store when pinned

Rename to `prepare_imagebuilder` and add a `tarball_path` parameter:

```python
def prepare_imagebuilder(release, target, subtarget, cache_dir, tarball_path=None):
    """Prepare the OpenWrt Image Builder directory.

    If tarball_path is provided (Nix store path), extract from there.
    Otherwise download from upstream.

    Extraction is cached in cache_dir keyed by tarball path to avoid
    re-extracting on repeated builds.
    """
    ib_name = f"openwrt-imagebuilder-{release}-{target}-{subtarget}.Linux-x86_64"

    if tarball_path:
        # Key cache by store path (content-addressed — safe to use as cache key)
        # Use the last two path components: hash + name
        store_path = Path(tarball_path)
        cache_key = store_path.parent.name  # nix store hash component
        ib_dir = cache_dir / f"store-{cache_key}" / ib_name
        if ib_dir.is_dir():
            print(f"  Using cached Image Builder: {ib_dir}")
            return ib_dir
        print(f"  Extracting from Nix store: {store_path}")
        extract_dir = cache_dir / f"store-{cache_key}"
        extract_dir.mkdir(parents=True, exist_ok=True)
        try:
            extract_tar_zst(store_path, extract_dir)
        except Exception as e:
            shutil.rmtree(extract_dir, ignore_errors=True)
            print(f"Error: Failed to extract Image Builder: {e}", file=sys.stderr)
            sys.exit(1)
        # Find extracted directory (handle minor naming variations)
        candidates = list(extract_dir.glob(f"openwrt-imagebuilder-{release}-{target}-{subtarget}*"))
        if not candidates:
            print("Error: Could not find extracted Image Builder directory", file=sys.stderr)
            sys.exit(1)
        return candidates[0]
    else:
        # Original download path
        return download_imagebuilder_from_upstream(release, target, subtarget, cache_dir)
```

Rename the old `download_imagebuilder` body to `download_imagebuilder_from_upstream`.

### 3.3 Update `main()` call site

```python
ib_dir = prepare_imagebuilder(
    build_info["release"],
    build_info["target"],
    build_info["subtarget"],
    args.cache_dir,
    tarball_path=build_info.get("imageBuilderTarball"),
)
```

---

## Step 4: Add `openwrt-prefetch-imagebuilder` app

A small shell helper that prints the `sha256` hash for a given Image Builder tarball,
ready to paste into `openwrt.nix`:

```nix
openwrt-prefetch-imagebuilder = {
  type = "app";
  program = let
    script = pkgs.writeShellScript "openwrt-prefetch-imagebuilder" ''
      set -euo pipefail
      if [ $# -lt 3 ]; then
        echo "Usage: nix run .#openwrt-prefetch-imagebuilder -- <release> <target> <subtarget>"
        echo ""
        echo "Fetches and prints the sha256 hash for an OpenWrt Image Builder tarball."
        echo "Add the output to imageBuilderHashes in lib/common/data/openwrt.nix."
        echo ""
        echo "Example:"
        echo "  nix run .#openwrt-prefetch-imagebuilder -- 24.10.5 mediatek mt7622"
        exit 1
      fi

      RELEASE="$1"
      TARGET="$2"
      SUBTARGET="$3"
      IB_NAME="openwrt-imagebuilder-''${RELEASE}-''${TARGET}-''${SUBTARGET}.Linux-x86_64"
      URL="https://downloads.openwrt.org/releases/''${RELEASE}/targets/''${TARGET}/''${SUBTARGET}/''${IB_NAME}.tar.zst"

      echo "Fetching: $URL"
      HASH=$(${pkgs.nix}/bin/nix-prefetch-url --type sha256 "$URL" 2>/dev/null)
      HASH_SRI=$(${pkgs.nix}/bin/nix hash to-sri --type sha256 "$HASH")

      echo ""
      echo "Add to imageBuilderHashes in lib/common/data/openwrt.nix:"
      echo ""
      echo "  \"$RELEASE\" = {"
      echo "    \"$TARGET/$SUBTARGET\" = \"$HASH_SRI\";"
      echo "  };"
    '';
  in "${script}";
};
```

Wire into `apps/openwrt/default.nix` and `apps/default.nix`.

---

## Step 5: Compute and populate hashes

Run for each unique target before implementing:

```bash
nix run .#openwrt-prefetch-imagebuilder -- 24.10.5 mediatek mt7622
nix run .#openwrt-prefetch-imagebuilder -- 24.10.5 realtek rtl838x
nix run .#openwrt-prefetch-imagebuilder -- 24.10.5 ramips mt7621
```

Paste results into `lib/common/data/openwrt.nix`.

---

## Step 6: Update workflow — release upgrades

The hash registry in `lib/common/data/openwrt.nix` needs updating whenever OpenWrt
publishes a new release. The `openwrt-build` app acts as orchestrator for this.

### The two-phase constraint

Hash updates require modifying a Nix source file, which means a fresh Nix evaluation
is needed before the updated hash takes effect in `openwrtConfigurations`. The
orchestration flow therefore has two phases with a file write between them:

```
openwrt-build bobcat --update
  │
  ├─[Phase 1: Update]
  │   ├── Query latest stable OpenWrt release from upstream
  │   ├── For each unique target in devices: compute sha256 of new tarball
  │   ├── Write updated imageBuilderHashes + defaultRelease to openwrt.nix
  │   └── (file on disk is now updated)
  │
  └─[Phase 2: Build — same as normal build]
      ├── nix build .#openwrtConfigurations.bobcat  (picks up new hash)
      ├── Extract ImageBuilder from fresh Nix store path
      └── make image
```

This is intentional: it mirrors how `nix flake update` works — modify source, then
rebuild. The build app shells out to `nix build` for re-evaluation, which it already
does implicitly by resolving `CONFIG_DIR` from `openwrtConfigurations`.

### 6.1 Release discovery

Query OpenWrt's download server for the latest stable release. The releases directory
at `https://downloads.openwrt.org/releases/` lists all releases as subdirectories.
Parse the listing to find the newest `XX.XX.X` stable release (exclude RCs):

```python
def fetch_latest_release():
    """Query downloads.openwrt.org to find the latest stable release version."""
    import urllib.request, re
    url = "https://downloads.openwrt.org/releases/"
    with urllib.request.urlopen(url) as resp:
        body = resp.read().decode()
    # Match versioned release directories like 24.10.5, 23.05.6
    versions = re.findall(r'href="(\d+\.\d+\.\d+)/"', body)
    if not versions:
        return None
    # Sort as tuples for correct ordering (24.10.5 > 23.05.6)
    return sorted(versions, key=lambda v: tuple(int(x) for x in v.split(".")))[-1]
```

### 6.2 Hash computation

For each unique `(release, target, subtarget)` tuple across all configured devices:

```python
def compute_imagebuilder_hash(release, target, subtarget):
    """Return the SRI sha256 hash of the Image Builder tarball."""
    ib_name = f"openwrt-imagebuilder-{release}-{target}-{subtarget}.Linux-x86_64"
    url = (
        f"https://downloads.openwrt.org/releases/{release}"
        f"/targets/{target}/{subtarget}/{ib_name}.tar.zst"
    )
    # Use nix store prefetch-file for correct SRI hash format
    result = subprocess.run(
        ["nix", "store", "prefetch-file", "--json", url],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)["hash"]
```

`nix store prefetch-file --json` downloads the file into the Nix store (or uses the
cached copy), outputs `{ "hash": "sha256-...", "storePath": "..." }`, and prints the
SRI hash — the same format used in `fetchurl`. This also warms the Nix store for the
subsequent `nix build .#openwrtConfigurations` call.

### 6.3 Updating `lib/common/data/openwrt.nix`

The Python builder modifies the Nix source file using regex replacement. The format of
`imageBuilderHashes` is designed to be machine-editable:

```python
def update_openwrt_nix(repo_root, new_release, new_hashes):
    """Update defaultRelease and imageBuilderHashes in lib/common/data/openwrt.nix.

    new_hashes: dict of { "target/subtarget": "sha256-..." } for the new release.
    Adds new_release entry to imageBuilderHashes; keeps older entries intact.
    """
    nix_file = Path(repo_root) / "lib/common/data/openwrt.nix"
    content = nix_file.read_text()

    # Update defaultRelease
    content = re.sub(
        r'(defaultRelease\s*=\s*")[^"]*(")',
        rf'\g<1>{new_release}\g<2>',
        content,
    )

    # Build the new release entry block
    hash_lines = "\n".join(
        f'    "{target}" = "{hash}";'
        for target, hash in sorted(new_hashes.items())
    )
    new_entry = f'  "{new_release}" = {{\n{hash_lines}\n  }};'

    # Insert or replace the entry for this release inside imageBuilderHashes
    # Strategy: find the imageBuilderHashes block and splice in the new entry.
    # If the release already exists, replace it; otherwise prepend it.
    if f'"{new_release}"' in content:
        # Replace existing entry for this release
        content = re.sub(
            rf'"{re.escape(new_release)}"\s*=\s*\{{[^}}]*\}};',
            new_entry,
            content,
        )
    else:
        # Insert after the opening brace of imageBuilderHashes
        content = re.sub(
            r'(imageBuilderHashes\s*=\s*\{)',
            rf'\1\n{new_entry}',
            content,
        )

    nix_file.write_text(content)
```

### 6.4 Orchestration in `openwrt-build` wrapper

Add an `--update` flag to the `openwrt-build` shell wrapper. When set, the wrapper
calls the Python builder in update mode before the normal build:

```bash
# --update flag handling in openwrt-build shell wrapper
if [[ " $* " =~ " --update " ]]; then
  echo "Checking for ImageBuilder updates..."
  ${builder}/bin/openwrt-update-imagebuilder \
    --repo-root "$REPO_ROOT" \
    --devices-file "$REPO_ROOT/lib/common/data/openwrt.nix" \
    --targets "${TARGETS_FOR_DEVICE}"  # derived from openwrtDevices at eval time
  # Re-evaluate config with updated hashes
  CONFIG_DIR=$(${pkgs.nix}/bin/nix build \
    ".#openwrtConfigurations.${DEVICE}" \
    --print-out-paths --no-link)
fi
```

The targets for the current device are embedded at eval time (known from
`device.target`/`device.subtarget`), so the update only computes hashes for the
targets actually needed for this build, not all devices. A `--update-all` flag can
trigger hashing all configured targets.

### 6.5 Behaviour when hash is missing (no `--update`)

If `imagebuilder-path` is absent from the config dir (because the hash isn't in the
registry yet), the Python builder falls back to downloading — same as today. But the
wrapper should also emit a clear notice:

```
Warning: ImageBuilder hash not registered for mediatek/mt7622 @ 24.10.5.
  Build will download the tarball but cannot guarantee reproducibility.
  Run with --update to pin this version.
```

This avoids blocking first-time builds while nudging toward pinning.

### 6.6 Update-only mode

For CI or pre-commit workflows, a standalone update command is useful:

```bash
nix run .#openwrt-build -- --update-pins          # update all targets
nix run .#openwrt-build -- bobcat --update-pins   # update only this device's targets
```

This modifies `lib/common/data/openwrt.nix` and exits without building. The user can
then commit the hash changes separately from the image build.

---

## Step 7: Update `CLAUDE.md`

```markdown
# Update Image Builder to latest release (modifies lib/common/data/openwrt.nix)
nix run .#openwrt-build -- --update-pins           # update all targets
nix run .#openwrt-build -- <device> --update       # update + build in one step
```

---

## Verification

1. `nix build .#openwrtConfigurations.bobcat` — builds without error; output contains
   `imagebuilder-path` file with a valid Nix store path
2. `cat $(nix build .#openwrtConfigurations.bobcat --print-out-paths)/imagebuilder-path`
   — prints something like `/nix/store/...-openwrt-imagebuilder-24.10.5-mediatek-mt7622.Linux-x86_64.tar.zst`
3. `nix-store --query --requisites $(nix build .#openwrtConfigurations.bobcat --print-out-paths)`
   — lists the imagebuilder tarball as a requisite
4. `nix run .#openwrt-build -- bobcat --no-secrets` — builds successfully using the
   Nix store tarball (check that "[3/5] Preparing Image Builder..." says "Extracting
   from Nix store" rather than "Downloading")
5. Subsequent builds: "[3/5]" should say "Using cached Image Builder"
6. `nix flake check --print-build-logs` — all existing tests pass

---

## Notes

- **Backwards compatibility**: If `imagebuilder-path` is absent (e.g., hash not in
  registry, or old config dir), the Python builder falls back to downloading. Zero
  breakage for existing workflows.
- **Shared derivation**: `pkgsFor nixpkgs "x86_64-linux"` already hardcodes the system
  for `openwrtConfigurations`. Adding `fetchurl` here doesn't make things *more*
  system-specific.
- **Storage**: ~50-80 MB per unique `(release, target, subtarget)`. Currently 3 tuples
  = ~150-240 MB total in the Nix store.
- **Updating hashes**: When upgrading to a new OpenWrt release, add a new entry to
  `imageBuilderHashes`. Old entries can be kept (they protect old GC roots) or pruned
  once GC roots are removed.
- **No derivation for extraction**: The extracted Image Builder directory (~500 MB+) is
  intentionally NOT put in the Nix store. It stays in `~/.cache/openwrt-builder/`.
  Only the tarball (content-hash-verified) goes in the store.
