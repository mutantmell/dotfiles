# Plan: Generalized OpenWrt Secrets Mechanism

## Problem

The secrets mechanism is partially hardcoded in `lib/openwrt/default.nix`. The
`mkSecretsMap` function has hardcoded logic that knows about specific network
names, and implicitly decides what is a secret based on device type. Adding a
new WiFi network (e.g., vGAME) requires editing code, not just config + secrets.

Additionally, the current design makes it unclear from reading the config which
fields will be secret-injected and what key name to use in the secrets YAML.

### What is wrong today

**`mkSecretsMap` for simpleAP/router** (`default.nix:794–797`): fully hardcoded
to `main`, pointing to `ap_2g`/`ap_5g` sections.

**`mkSecretsMap` for meshAP IoT hack** (`default.nix:766–792`): special-cases
the literal string `"iot"` to detect extra networks added via `extraConfig`.

**Implicit and opinionated**: the code decides that SSIDs are secrets. A
different operator might not consider SSIDs secret. There is no way to opt out
of treating a field as a secret without changing code.

---

## Approaches Considered

### Option A: UCI commands in secrets file

Rejected. Requires hand-authoring UCI syntax outside Nix.

### Option B: Token strings in config values (user-proposed)

The Nix config emits literal token strings (e.g., `"@@wifi_ssids.game@@"`) for
fields that need secret injection. The build script scans the UCI script for
those tokens and substitutes values from the secrets YAML.

Advantage: explicit — looking at the Nix config, you see exactly which fields
are secrets and what key name is expected in the secrets file.

Disadvantage relative to approach C below: the "magic" moves to runtime string
scanning; the UCI script contains sentinel strings that aren't real values; and
the secrets map becomes an emergent property of scanning text rather than a
first-class Nix value.

### Option C: `_secret` markers in the Nix config (recommended)

Fields that require secret injection are declared with a special marker value
`{ _secret = "key.name"; }` in the Nix attrset. The UCI generator skips these
fields (leaves them unset). `mkSecretsMap` is derived automatically by
traversing the config for markers. The build script pipeline (including
`merge_secrets_into_uci`) is unchanged.

**This gives the same explicit interface advantage as tokens, but keeps secrets
as a first-class concept in Nix rather than a runtime text-scanning convention.**

---

## Recommended Solution: `_secret` Markers

### How it works

In any Nix config attrset, a field can be declared as needing secret injection:

```nix
batmesh = {
  _type = "wifi-iface";
  mode = "mesh";
  ...
  mesh_id = { _secret = "mesh_id"; };
  key     = { _secret = "mesh_key"; };
};

ap_2g_main = {
  _type = "wifi-iface";
  mode = "ap";
  ...
  ssid = { _secret = "wifi_ssids.main"; };
  key  = { _secret = "wifi_keys.main"; };
};
```

`"mesh_id"` etc. are the flat key names that must appear in `wifi.yaml`. The
operator decides per-field whether something is a secret — SSIDs can be
non-secret if the operator doesn't care.

### Component changes

#### 1. `lib/openwrt/uci.nix` — skip `_secret` fields

The UCI renderer currently emits `uci set config.section.key='value'` for every
field. Add a guard: if the value is an attrset with a `_secret` key, skip
it entirely. The field is left unset until secrets are applied.

```nix
isSecret = v: builtins.isAttrs v && v ? _secret;

# In the per-option rendering loop:
# if isSecret v then "" (omit) else current rendering
```

No other changes to `uci.nix`.

#### 2. `lib/openwrt/default.nix` — rewrite `mkSecretsMap`

Replace the hardcoded type-branching with a recursive traversal that collects
all `_secret` markers from the generated config:

```nix
mkSecretsMap = { device, owrtData }:
  let
    config = mkDeviceConfig { inherit device owrtData; };

    # Traverse a value. For an option value, returns the secret key if marked.
    collectSecrets = uciPath: v:
      if builtins.isAttrs v && v ? _secret then
        # Leaf: this is a secret field.  uciPath is e.g. "wireless.ap_2g_main.ssid"
        { "${v._secret}" = [ uciPath ]; }
      else if builtins.isAttrs v && !(v ? _secret) then
        # Recurse into sections / configs
        lib.foldlAttrs
          (acc: k: child:
            let childPath = if uciPath == "" then k else "${uciPath}.${k}";
            in lib.recursiveUpdate acc (collectSecrets childPath child))
          {}
          (builtins.removeAttrs v [ "_type" "_anonymous" ])
      else
        {};

  in collectSecrets "" config;
```

`lib.recursiveUpdate` is used to merge entries for the same secret key across
multiple UCI paths (e.g., the same SSID set on both `ap_2g_main` and
`ap_5g_main`).

#### 3. Wireless config generation — add explicit `_secret` declarations

Update `mkMeshWirelessConfig`, `mkSimpleAPWirelessConfig`, and `mkRouterConfig`
to include `_secret` markers at the fields that need injection:

**`mkMeshWirelessConfig`** — mesh interface:

```nix
batmesh = {
  _type = "wifi-iface";
  ...
  mesh_id = { _secret = "mesh_id"; };
  key     = { _secret = "mesh_key"; };
};
```

**`mkMeshWirelessConfig`** — AP interfaces (generated per-network):

```nix
"ap_2g_${name}" = {
  ...
  ssid = { _secret = "wifi_ssids.${name}"; };
  key  = { _secret = "wifi_keys.${name}"; };
};
```

**`mkSimpleAPWirelessConfig`** and router:

```nix
ap_2g = {
  ...
  ssid = { _secret = "wifi_ssids.main"; };
  key  = { _secret = "wifi_keys.main"; };
};
```

The `_secret` key name is chosen freely by the Nix author at the point of
declaration. It is the flat dotted key that must exist in `wifi.yaml`.

#### 4. `build.py` — no changes

`merge_secrets_into_uci` already reads `secretsMap` from `build.json` and
injects `uci set` commands generically. The format of `secretsMap` does not
change.

#### 5. `mkSecretsApplyScript` — no changes needed

It already derives from `mkSecretsMap`. Updates automatically.

---

## Result: Adding a New Network

To add a WiFi network for the vGAME VLAN, the operator:

1. **Updates Nix config** (`lib/openwrt/default.nix` or device file):
   Adds a new AP interface with explicit `_secret` markers:

   ```nix
   "ap_2g_game" = {
     _type = "wifi-iface";
     device = "radio0";
     mode = "ap";
     network = "game";
     encryption = "sae-mixed";
     ssid = { _secret = "wifi_ssids.game"; };
     key  = { _secret = "wifi_keys.game"; };
   };
   ```

2. **Updates `wifi.yaml`**:

   ```yaml
   wifi_ssids:
     game: "GameNetworkSSID"
   wifi_keys:
     game: "GameNetworkPassphrase"
   ```

3. Done. `mkSecretsMap` traverses the config and finds the new markers. No
   build script changes. No other code changes.

---

---

## Secrets Delivery: Decoupling sops from the Build Script

### Problem

The build script (`build.py`) currently calls `sops -d` directly. This
conflates two concerns: where secrets come from (sops, `/run/secrets/`, etc.)
and how they are used (flatten → merge into UCI). In a deployed service the
build process will not have access to the sops key or the encrypted file;
sops-nix will have already decrypted the secrets to `/run/secrets/`.

### Solution: build script is sops-agnostic

`build.py` accepts a **plain (pre-decrypted) YAML file** via `--secrets-file`.
It never calls `sops -d`. The caller is responsible for decryption.

For local development the shell wrapper (`apps/openwrt/default.nix`) pipes
`sops -d` output directly into the build script via stdin (using `-` as the
path sentinel), avoiding any temp file on disk:

```bash
sops -d "$SOPS_FILE" | openwrt-build --secrets-file -
```

For a deployed NixOS service, sops-nix decrypts the file to `/run/secrets/` and
the service passes the path directly:

```bash
openwrt-build --secrets-file /run/secrets/openwrt-wifi
```

### sops-nix format: binary

`wifi.yaml` must be encrypted in sops **binary format** (not the default YAML
format). The YAML format encrypts individual values but leaves key names and
structure visible in the committed file — on a public repo this leaks the
structure of the secrets (key names such as `wifi_ssids`, `mesh_id`). Binary
format encrypts the entire file content as a blob, revealing nothing.

The sops-nix NixOS declaration for a build service:

```nix
sops.secrets.openwrt-wifi = {
  sopsFile = ./secrets/wifi.yaml;
  format = "binary";
  # Decrypts to /run/secrets/openwrt-wifi (plain YAML) on tmpfs
  # Permissions and ownership set as appropriate for the build service user
};
```

### Security properties

| Concern                                           | Mitigation                                                                                           |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Encrypted file in git leaks key names             | Binary sops format — entire content is opaque                                                        |
| Plain secrets written to disk during local dev    | Avoided by piping through stdin; secrets exist only in kernel pipe buffer                            |
| Plain secrets written to disk in deployed service | `/run/secrets/` is tmpfs (in-memory); mode `0400`, restricted ownership                              |
| UCI script temp dir contains baked-in secrets     | `chmod 0o700` on temp dir; `finally` block cleanup; unavoidable since Image Builder needs real files |
| Output `.bin` image contains secrets              | Treat as sensitive; restrict output directory permissions                                            |

### Future integration: dedicated build service

When this build pipeline is run by a NixOS service rather than interactively,
the following three steps integrate it with sops-nix:

1. **Declare the secret on the host.** Add a sops-nix secret that decrypts
   the entire `wifi.yaml` as a single file. Use `format = "binary"` — this
   decrypts the whole file content as a blob. Do not set `key`; that attribute
   is for extracting a named field from a YAML-format sops file, which is not
   what we want here.

   ```nix
   sops.secrets.openwrt-wifi = {
     sopsFile = ./secrets/wifi.yaml;
     format = "binary";
     # Produces /run/secrets/openwrt-wifi containing the plain YAML
   };
   ```

2. **Set permissions for the builder user.** By default sops-nix creates
   secrets as `mode = "0400"` owned by root. Grant the build service user
   access:

   ```nix
   sops.secrets.openwrt-wifi.owner = "openwrt-builder";
   # or use group + mode if multiple users need access
   ```

3. **Pass the decrypted file to the builder.** Configure the service to
   invoke the builder with:
   ```bash
   openwrt-build --secrets-file /run/secrets/openwrt-wifi ...
   ```
   No sops tooling or keys need to be available to the build service itself.

### Files Changed (this section)

| File                                | Change                                                                     |
| ----------------------------------- | -------------------------------------------------------------------------- |
| `packages/openwrt-builder/build.py` | Remove `decrypt_secrets`; accept `-` for stdin; read plain YAML directly   |
| `apps/openwrt/default.nix`          | Pipe `sops -d` to build script via stdin instead of passing sops file path |

---

## Files Changed (full)

| File                                    | Change                                                                                                                                             |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lib/openwrt/uci.nix`                   | Skip fields whose value is `{ _secret = "..."; }`                                                                                                  |
| `lib/openwrt/default.nix`               | Add `_secret` markers to wireless interface declarations; rewrite `mkSecretsMap` to traverse the config recursively; remove `mkSecretsApplyScript` |
| `hosts/openwrt/derfflinger.nix`         | Add explicit `_secret` markers to IoT AP interface                                                                                                 |
| `flake.nix`                             | Remove `secretsApply` field from manifest                                                                                                          |
| `packages/openwrt-builder/build.py`     | Remove sops decryption; accept plain YAML via `--secrets-file -` (stdin)                                                                           |
| `apps/openwrt/default.nix`              | Pipe `sops -d` to build script stdin                                                                                                               |
| `hosts/openwrt/secrets/wifi.yaml`       | Re-encrypt in binary format (separate step, not in this commit)                                                                                    |
| `hosts/openwrt/default.nix`             | Update stale comment                                                                                                                               |
| `tests/lib/openwrt-config.nix`          | Update section names and secret marker assertions                                                                                                  |
| Device `.nix` files in `hosts/openwrt/` | No changes (except derfflinger above)                                                                                                              |

---

## Resolved Design Questions

1. **`{ _secret = "key"; }` is unambiguous.** `uci.nix:toUCIValue` handles
   strings, booleans, integers, and lists only — it throws on any other attrset
   (`"Unsupported UCI value type: set"`). So attrset option values are currently
   illegal, making the sentinel unambiguous. The guard is added in
   `renderSectionOptions` alongside the existing `null` guard.

2. **Traversal path format is correct.** The three-level config structure
   (config name → section name → option name) produces `wireless.ap_2g_main.ssid`
   via dot-concatenation, which is exactly what `merge_secrets_into_uci` passes
   to `uci -q set ${uci_path}='${value}'`. No adjustment needed.

3. **`_type` and `_anonymous` must be explicitly stripped during traversal.**
   Both are strings/booleans so they would not trigger `_secret` detection, but
   excluding them explicitly (mirroring `uci.nix:79,97`) is the right defensive
   choice: if either were ever accidentally written as an attrset, they would
   produce bogus paths like `wireless.ap_2g_main._type` in the secrets map.

4. **`{ _secret = "..." }` inside list values: deferred.** All current secrets
   are single-valued options. Supporting list-element secrets would complicate
   the traversal for no current benefit.
