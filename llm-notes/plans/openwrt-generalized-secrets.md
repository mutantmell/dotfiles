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

## Files Changed

| File | Change |
|------|--------|
| `lib/openwrt/uci.nix` | Skip fields whose value is `{ _secret = "..."; }` |
| `lib/openwrt/default.nix` | Add `_secret` markers to wireless interface declarations; rewrite `mkSecretsMap` to traverse the config recursively |
| `hosts/openwrt/secrets/wifi.yaml` | Add new network entries only when adding networks — no structural change for this refactor |
| `packages/openwrt-builder/build.py` | No changes |
| `apps/openwrt/default.nix` | No changes |
| Device `.nix` files in `hosts/openwrt/` | No changes |

---

## Open Questions

1. **Naming convention for `_secret` attrset**: `{ _secret = "key"; }` is the
   proposed sentinel. It must not be a valid UCI value. Since UCI values are
   strings, booleans, integers, or lists — a single-key attrset with a
   leading underscore is unambiguous. Confirm this is acceptable.

2. **Recursive traversal depth**: The traversal walks `config` which is a
   `{ wireless = { ... }; network = { ... }; ... }` structure. The path
   accumulation produces `wireless.ap_2g_main.ssid` which is the correct UCI
   path format. Confirm this matches how `merge_secrets_into_uci` constructs
   `uci set` calls (it does: `uci -q set ${uci_path}='${value}'`).

3. **Should the `_type` / `_anonymous` fields be explicitly excluded from
   traversal?** Yes — they are rendering hints, not UCI sections or options.
   They are already excluded in the pseudocode above via `removeAttrs`.

4. **List values with `_secret`**: Should `{ _secret = "..."; }` be allowed as
   a list element (for `add_list` fields)? This is a possible extension but not
   needed now. Defer unless a use case arises.
