# Plan: Migrate Scripts to TypeScript + Deno

## Status: Shelved — waiting for Deno-in-Nix packaging to mature

## Goal

Replace bash and python scripts with TypeScript + Deno, bundled as Nix packages with app wrappers to manage dependencies. This enables:

- **Type-safe Nix integration:** Generate JSON from `nix eval` and consume it with typed interfaces, eliminating fragile string parsing (e.g., grep/sed on `.sops.yaml`, partition type detection via nested `nix eval` calls).
- **Single scripting language:** Consolidate bash and python into one stack.
- **Better testability:** Unit test script logic without running full deployments.
- **Flake-injected values:** Pass host metadata, guest lists, network config, and disko profiles directly from Nix into scripts as structured data (JSON/env), rather than rediscovering them at runtime.

## Design Decisions

### Nix Value Injection: Hybrid Approach

Use **build-time JSON generation** for stable config and **runtime `nix eval --json`** for values that depend on uncommitted changes.

**Build-time (baked into app wrapper by Nix):**
- Host profile type (router vs vm-host) — derived from disko config
- MicroVM UID per host
- Guest lists (microvm and incus) per host
- KVM GID (system constant)

**Runtime (script calls `nix eval --json`):**
- Nothing initially — all needed values can be determined at build time from the flake

The Nix app wrapper generates a JSON config file in the Nix store and passes its path to the TypeScript entrypoint via `--config <path>` or an environment variable.

```nix
# Example: apps/deploy/default.nix
hostConfigs = lib.mapAttrs (hostname: nixosCfg: {
  profile = if hasLuksPartition nixosCfg then "router" else "vm-host";
  microvmUid = nixosCfg.config.common.microvm.uid or null;
  kvmGid = 302;
  microvmGuests = lib.attrNames (nixosCfg.config.microvm.vms or {});
  incusGuests = /* derive from incus guest configs */;
}) nixosConfigurations;

configFile = pkgs.writeText "deploy-config.json" (builtins.toJSON hostConfigs);
```

### Deno Packaging in Nix: Source Bundle + `deno run`

Use `stdenv.mkDerivation` to vendor dependencies and bundle source, then `makeWrapper` to create a bin that runs `deno run` with the vendored source. This avoids `deno compile` complexity and matches the existing openwrt-builder pattern.

```nix
# packages/deploy-nixos-anywhere/default.nix
stdenv.mkDerivation {
  pname = "deploy-nixos-anywhere";
  src = ./.;
  nativeBuildInputs = [ deno makeWrapper ];
  buildPhase = ''
    export DENO_DIR=$TMPDIR/deno
    deno cache src/main.ts  # download deps into DENO_DIR
  '';
  installPhase = ''
    mkdir -p $out/share/deploy-nixos-anywhere $out/bin
    cp -r src deno.json deno.lock $out/share/deploy-nixos-anywhere/
    cp -r $TMPDIR/deno $out/share/deploy-nixos-anywhere/.deno-cache
    makeWrapper ${deno}/bin/deno $out/bin/deploy-nixos-anywhere \
      --set DENO_DIR $out/share/deploy-nixos-anywhere/.deno-cache \
      --add-flags "run --allow-all $out/share/deploy-nixos-anywhere/src/main.ts" \
      --prefix PATH : ${lib.makeBinPath runtimeDeps}
  '';
}
```

Runtime deps injected via `makeWrapper --prefix PATH`: `openssh`, `ssh-to-age`, `sops`, `nix`, `coreutils`, `git`.

### Shell Command Integration: dax

Use [dax](https://github.com/dsherret/dax) (`jsr:@david/dax`) for subprocess execution. It provides:
- Tagged template literal syntax: `` await $`ssh ${target} "command"` ``
- Output capture: `.text()`, `.json()`, `.lines()`, `.code()`
- Piping: `` $`cmd1`.pipe($`cmd2`) ``
- Stdin injection: `` $`sops updatekeys --yes ${file}`.stdinText(input) ``
- Auto-escaping of interpolated arguments
- Throws on non-zero exit by default (`.noThrow()` to opt out)

This replaces all manual `Deno.Command` usage and gives bash-like ergonomics with type safety.

### Shared Code: Common Module

Shared utilities live in `packages/deploy-common/src/` and are imported by both scripts:

```
packages/
  deploy-common/
    src/
      sops.ts          # .sops.yaml read/update, age key derivation
      ssh-keys.ts      # SSH key generation, reading, backup to .keys/
      nix-config.ts    # TypeScript interfaces for the injected JSON config
      types.ts         # Shared type definitions
  deploy-nixos-anywhere/
    src/main.ts
    deno.json          # imports deploy-common via workspace or relative path
  setup-incus-guests/
    src/main.ts
    deno.json
```

## Scripts to Migrate

| Current script | Language | Priority | Notes |
|---|---|---|---|
| `scripts/deploy-nixos-anywhere.sh` | bash | **P0** | Primary candidate. Highest complexity, most pain points. |
| `scripts/setup-incus-guests.sh` | bash | **P1** | Small, tightly coupled with deploy script. Migrate immediately after. |
| OpenWrt scripts (builder, deployer) | Python | **P2** | Already well-structured. Migrate only if/when they need significant changes. |

## Migration Order

### Phase 1: Scaffolding & Shared Library

1. Set up `packages/deploy-common/` with shared types and utilities
2. Set up `packages/deploy-nixos-anywhere/` with Deno project structure
3. Create `packages/deploy-nixos-anywhere/default.nix` derivation
4. Create `apps/deploy/default.nix` with Nix-side JSON config generation
5. Wire into flake.nix as `packages.x86_64-linux.deploy-nixos-anywhere` and `apps.x86_64-linux.deploy`

### Phase 2: Deploy Script Core Logic

Rewrite `scripts/deploy-nixos-anywhere.sh` as TypeScript modules:

#### 2a. Config & Types (`deploy-common/src/`)

```typescript
// types.ts
interface HostConfig {
  profile: "router" | "vm-host";
  microvmUid: number | null;
  kvmGid: number;
  microvmGuests: string[];
  incusGuests: string[];
}

type DeployConfig = Record<string, HostConfig>;
```

```typescript
// sops.ts — replaces grep/sed on .sops.yaml
import { parse, stringify } from "jsr:@std/yaml";

export function updateSopsAnchor(
  sopsPath: string,
  anchorName: string,
  agePublicKey: string,
): { changed: boolean; needsManualAdd: boolean };

export async function reencryptSecrets(
  repoRoot: string,
  hostname: string,
  guestName?: string,
): Promise<void>;
```

```typescript
// ssh-keys.ts — replaces ad-hoc ssh-keygen/ssh-to-age calls
export async function ensureSshHostKey(
  keysDir: string,
  name: string,
): Promise<{ privateKey: string; publicKey: string; existed: boolean }>;

export async function deriveAgeKey(publicKeyPath: string): Promise<string>;
```

#### 2b. Main Deploy Flow (`deploy-nixos-anywhere/src/main.ts`)

The main script orchestrates the same phases as the bash version, but with structured data:

```typescript
import $ from "jsr:@david/dax";

// 1. Parse CLI args (hostname, target-ip, extra-args)
// 2. Load config from --config JSON (injected by Nix wrapper)
// 3. hostConfig = config[hostname] — profile, guests, uid all known
// 4. Disk encryption key setup (profile-dependent)
// 5. SSH host key setup (ensure + backup to .keys/)
// 6. Deployment summary + confirmation prompts
// 7. sops.yaml update (using yaml parser, not sed)
//    - Update anchor for host
//    - Update anchors for each guest (from hostConfig.microvmGuests + incusGuests)
//    - Re-encrypt affected secret files
// 8. Prepare extra-files directory (microvm guest keys + image dirs)
// 9. nixos-anywhere phase 1: kexec + disko
// 10. Profile-dependent SSH commands (bind mount or zfs keylocation)
// 11. nixos-anywhere phase 2: install + extra-files
// 12. Profile-dependent post-install (disk key push or chown)
// 13. Hardware config fetch
// 14. Post-deploy instructions
```

Key improvements over bash version:
- **No `nix eval` at runtime** — profile and guest lists come from build-time JSON
- **YAML parser** for `.sops.yaml` — no grep/sed, can add new anchors programmatically
- **Typed guest iteration** — `for (const guest of hostConfig.microvmGuests)` instead of `ls | while read`
- **Structured error handling** — dax throws on command failure, try/catch for recovery
- **Shared key management** — `ensureSshHostKey()` used for both host and guest keys

#### 2c. sops.yaml Handling Detail

The current bash script can only update existing anchors (via sed) or print manual instructions for new ones. The TypeScript version can handle both cases programmatically:

```typescript
// Read .sops.yaml as structured data
// The file uses YAML anchors (&sv_hostname) which standard parsers preserve
// Find or create the anchor entry in creation_rules
// Update the age key value
// Write back, preserving anchor syntax
```

**Caveat:** YAML anchors (`&sv_hostname`) are not universally preserved by all YAML libraries. Test with `@std/yaml` to confirm anchor round-tripping works. If not, fall back to line-based manipulation (still better than sed — can use proper string matching).

### Phase 3: Setup Incus Guests Script

Rewrite `scripts/setup-incus-guests.sh` — straightforward since it's small:

```typescript
import $ from "jsr:@david/dax";

// 1. Load config, get incusGuests list for hostname
// 2. For each guest:
//    a. Read SSH key from .keys/
//    b. Push private key via: ssh target "incus file push - ${guest}/etc/ssh/..."
//    c. Push public key
//    d. Restart sshd: ssh target "incus exec ${guest} -- systemctl restart sshd"
//    e. Trigger rebuild: ssh target "incus exec ${guest} -- nixos-rebuild switch"
```

### Phase 4: Cleanup & Documentation

1. Remove `scripts/deploy-nixos-anywhere.sh` and `scripts/setup-incus-guests.sh`
2. Update CLAUDE.md with new commands:
   ```
   nix run .#deploy -- <hostname> <target-ip> [extra-args]
   nix run .#setup-incus-guests -- <hostname> <target-host>
   ```
3. Add unit tests for shared library functions (sops.yaml parsing, key path logic)

### Phase 5 (Future): OpenWrt Migration

Evaluate migrating `packages/openwrt-builder/build.py` and `packages/openwrt-deployer/deploy.sh` to TypeScript. Only pursue if significant changes are needed — they work well as-is.

## Nix Flake Wiring

```nix
# flake.nix additions

# Packages
packages.x86_64-linux.deploy-nixos-anywhere =
  import ./packages/deploy-nixos-anywhere {
    inherit (pkgs) stdenv deno makeWrapper openssh ssh-to-age sops nix git;
  };

packages.x86_64-linux.setup-incus-guests =
  import ./packages/setup-incus-guests {
    inherit (pkgs) stdenv deno makeWrapper openssh;
  };

# Apps (with build-time config injection)
apps.x86_64-linux.deploy = {
  type = "app";
  program = toString (import ./apps/deploy {
    inherit pkgs lib;
    inherit (self) nixosConfigurations;
    deploy-nixos-anywhere = self.packages.x86_64-linux.deploy-nixos-anywhere;
  });
};

apps.x86_64-linux.setup-incus-guests = {
  type = "app";
  program = toString (import ./apps/deploy/setup-incus-guests.nix {
    inherit pkgs;
    setup-incus-guests = self.packages.x86_64-linux.setup-incus-guests;
  });
};
```

## Testing Strategy

### Unit Tests (Deno test runner, run in `nix flake check`)
- sops.yaml anchor detection and update logic (mock file content)
- SSH key path resolution
- Config parsing and validation
- Profile-dependent logic branching

### Integration Testing
- Manual: deploy to a test VM to validate the full flow
- The deploy script is inherently destructive (wipes disks), so automated integration tests are impractical

### Nix Check
```nix
checks.x86_64-linux.deploy-tests = pkgs.stdenv.mkDerivation {
  name = "deploy-tests";
  src = ./packages;
  nativeBuildInputs = [ pkgs.deno ];
  buildPhase = ''
    export DENO_DIR=$TMPDIR/deno
    cd deploy-common && deno test
  '';
  installPhase = "touch $out";
};
```

## File Structure (Final)

```
packages/
  deploy-common/
    src/
      sops.ts
      ssh-keys.ts
      nix-config.ts
      types.ts
      mod.ts             # re-exports
    deno.json
  deploy-nixos-anywhere/
    src/
      main.ts
      phases.ts          # nixos-anywhere phase orchestration
      disk-keys.ts       # encryption key generation/reading
      prompts.ts         # user confirmation prompts
    default.nix
    deno.json
    deno.lock
  setup-incus-guests/
    src/
      main.ts
    default.nix
    deno.json
    deno.lock
apps/
  deploy/
    default.nix          # app wrapper, generates JSON config from nixosConfigurations
    setup-incus-guests.nix
```

## Places That Motivate This Migration

- `scripts/deploy-nixos-anywhere.sh` — profile detection via `nix eval` with fragile `--apply` expressions
- `scripts/deploy-nixos-anywhere.sh` — guest discovery via `ls` on directory structure instead of querying the Nix config
- `scripts/deploy-nixos-anywhere.sh` — .sops.yaml manipulation via sed
- `scripts/setup-incus-guests.sh` — guest list discovery duplicated from deploy script
- Both scripts share key management logic that is copy-pasted rather than shared

## Priority: Soon

These scripts run infrequently (new host deploys, hardware failures) but must work correctly when needed — often under time pressure. The current bash versions silently bitrot: guest lists discovered via `ls` can miss config changes, profile detection via `nix eval --apply` breaks if disko schema evolves, and hardcoded constants (KVM GID, paths) drift from reality. Build-time Nix value injection makes these scripts structurally unable to fall out of sync with the flake config. The cost of migration is modest and the payoff is confidence that `nix run .#deploy` will just work months from now without debugging stale assumptions.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| YAML anchor round-tripping in `@std/yaml` | Test early in Phase 1; fall back to regex-based approach if anchors aren't preserved |
| Deno cache reproducibility in Nix sandbox | Use `deno cache` with lockfile in build phase; vendor deps into derivation output |
| `deno run` startup overhead vs bash | Negligible for a deployment script that takes minutes; not a concern |
| Breaking working deploy flow during migration | Keep bash scripts until TypeScript version is validated end-to-end on a real deploy |
| **Deno packaging in Nix is unsupported** | **See below — this is the primary blocker** |

## Blocker: Deno-in-Nix Packaging Maturity

There is no `buildDenoPackage` in nixpkgs. Three attempts to add one have failed:

1. **[nixpkgs#407434](https://github.com/NixOS/nixpkgs/pull/407434)** (June 2025) — `buildDenoPackage` + `fetchDenoDepends` merged by aMOPel, providing a `buildGoModule`-style helper for Deno apps. Used fixed-output derivations (FODs) wrapping Deno's internal package cache.

2. **[nixpkgs#417591](https://github.com/NixOS/nixpkgs/pull/417591)** (June 2025, one day later) — Reverted. Reviewers raised concerns that relying on Deno's undocumented internal cache format meant FOD outputs could silently break reproducibility if upstream changed behavior. Maintainers requested a decoupled fetcher approach (like Cargo/Yarn).

3. **[nixpkgs#453904](https://github.com/NixOS/nixpkgs/pull/453904)** (Oct 2025 – Feb 2026) — Second attempt with `fetchDenoDeps`. After 9 months of review cycles, the author abandoned the effort, noting a catch-22: the feature needed substantial code to be complete, but the resulting PR was too large for volunteer maintainers to review. The author created [deno2nix](https://github.com/aMOPel/deno2nix) as an independent project instead.

**Impact on this plan:** The "source bundle + `deno run`" packaging approach described above is hand-rolled plumbing that `buildDenoPackage` was supposed to provide. Without upstream support, we'd be maintaining custom derivation logic that could break on any Deno version bump (cache format changes, lockfile format changes). This is exactly the fragility this migration was supposed to eliminate.

**Options:**
- **Wait** for `deno2nix` or a nixpkgs builder to stabilize before proceeding
- **Evaluate alternatives** — Python (mature `buildPythonApplication`), Go (mature `buildGoModule`), or Rust (mature `buildRustPackage`) all have first-class Nix support. The core goals (typed config, YAML parsing, Nix value injection) don't require Deno specifically.
- **Proceed anyway** with hand-rolled packaging, accepting the maintenance risk
