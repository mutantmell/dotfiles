# WiFi Secrets Refactor Plan

## Goal

Restructure the secrets YAML format so that related secrets (SSID and key for the same network) are co-located, rather than split across two sibling sections.

No backwards-compatibility constraint: no devices have been deployed yet.

---

## Current State

### YAML secrets format (conceptual)

```yaml
mesh_id: "mesh-network-id"
mesh_key: "mesh-password"
wifi_ssids:
  main: "HomeNetwork"
  secondary: "HomeNetwork-5G"
  iot: "HomeNetwork-IoT"
wifi_keys:
  main: "password123"
  secondary: "password456"
  iot: "iot-password"
```

`flatten_yaml()` produces dot-separated keys: `mesh_id`, `mesh_key`, `wifi_ssids.main`, `wifi_keys.main`, …

### `_secret` markers in `lib/openwrt/default.nix`

```nix
mesh_id = { _secret = "mesh_id"; };
key      = { _secret = "mesh_key"; };
ssid = { _secret = "wifi_ssids.${name}"; };
key  = { _secret = "wifi_keys.${name}"; };
```

### `secretsMap` in `build.json` (auto-generated from markers)

```json
{
  "mesh_id":         ["wireless.batmesh.mesh_id"],
  "mesh_key":        ["wireless.batmesh.key"],
  "wifi_ssids.main": ["wireless.ap_2g_main.ssid", "wireless.ap_5g_main.ssid"],
  "wifi_keys.main":  ["wireless.ap_2g_main.key",  "wireless.ap_5g_main.key"],
  ...
}
```

---

## Problem

SSID and key for the same network are spread across `wifi_ssids.*` and `wifi_keys.*`. Someone editing the YAML has to mentally join two separate sections to understand a single network's credentials. The flat underscore-separated names (`wifi_ssids`, `wifi_keys`) are also an ad-hoc convention with no obvious structure.

---

## Proposed Change

Group SSID and key for each network together:

```yaml
wifi:
  main:
    ssid: "HomeNetwork"
    key: "password123"
  secondary:
    ssid: "HomeNetwork-5G"
    key: "password456"
  iot:
    ssid: "HomeNetwork-IoT"
    key: "iot-password"
  mesh:
    id: "mesh-network-id"
    key: "mesh-password"
```

`flatten_yaml()` (unchanged) now produces: `wifi.main.ssid`, `wifi.main.key`, `wifi.mesh.id`, `wifi.mesh.key`, …

The hierarchy directly expresses the intent: a wifi network has an ssid and a key; mesh is a wifi network too (802.11s interface mode), so it lives alongside the AP networks under `wifi`.

---

## Files Changed

### 1. `lib/openwrt/default.nix` — update `_secret` markers

| Old | New |
|-----|-----|
| `{ _secret = "mesh_id"; }` | `{ _secret = "wifi.mesh.id"; }` |
| `{ _secret = "mesh_key"; }` | `{ _secret = "wifi.mesh.key"; }` |
| `{ _secret = "wifi_ssids.${name}"; }` | `{ _secret = "wifi.${name}.ssid"; }` |
| `{ _secret = "wifi_keys.${name}"; }` | `{ _secret = "wifi.${name}.key"; }` |

`mkSecretsMap` is a pure function of the device config, so the generated `secretsMap` keys update automatically — no other Nix changes needed.

### 2. `tests/lib/openwrt-config.nix` — update secret-key assertions

| Old assertion | New assertion |
|---|---|
| `meshSecretsMap ? mesh_id` | `meshSecretsMap ? "mesh.id"` |
| `meshSecretsMap ? mesh_key` | `meshSecretsMap ? "mesh.key"` |
| `meshSecretsMap ? "wifi_ssids.main"` | `meshSecretsMap ? "wifi.main.ssid"` |
| `meshSecretsMap ? "wifi_keys.main"` | `meshSecretsMap ? "wifi.main.key"` |
| `meshSecretsMap ? "wifi_ssids.secondary"` | `meshSecretsMap ? "wifi.secondary.ssid"` |
| `meshSecretsMap."wifi_ssids.main"` (length check) | `meshSecretsMap."wifi.main.ssid"` |
| `simpleAPSecretsMap ? "wifi_ssids.main"` | `simpleAPSecretsMap ? "wifi.main.ssid"` |
| `simpleAPSecretsMap ? "wifi_keys.main"` | `simpleAPSecretsMap ? "wifi.main.key"` |
| `simpleAPSecretsMap."wifi_ssids.main"` (length check) | `simpleAPSecretsMap."wifi.main.ssid"` |
| `routerSecretsMap ? "wifi_keys.main"` | `routerSecretsMap ? "wifi.main.key"` |
| `sm ? "wifi_ssids.iot"` (derfflinger) | `sm ? "wifi.iot.ssid"` |

### 3. `apps/openwrt/default.nix` — update YAML format comment

Update the example in the comment block (lines 29–39) to show the new grouped format. No logic changes.

### 4. `packages/openwrt-builder/build.py` — no changes needed

`flatten_yaml()` and `merge_secrets_into_uci()` are format-agnostic; they work on whatever flat key→value dict comes out of the YAML. The new format flattens to the new keys, which match the updated secretsMap. Nothing in the builder needs to change.

---

## Testing

```bash
# Pure eval (fast — verifies Nix-side marker renames and secretsMap output)
nix-instantiate --eval --strict tests/lib/openwrt-config.nix

# Or via flake check
nix build .#checks.x86_64-linux.openwrt-config

# Build smoke-test
nix run .#openwrt-build -- bobcat --no-secrets
```
