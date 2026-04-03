# Raspberry Pi 4 — NixOS Device Profile Specification

## Overview

This document specifies the complete requirements for a Raspberry Pi 4 running NixOS as a dedicated, stateless IoT hub. The Pi acts as the home automation protocol translation layer: it reads SwitchBot Meter Plus BLE advertisements and (when added) manages Zigbee devices, publishing all data to a local MQTT broker. A Prometheus exporter exposes metrics for scraping by the NAS. The Pi has no persistent local state and is designed to boot cleanly from the network with no SD card installed.

The mental model for this device is a hardware-instantiated MicroVM. Physical isolation replaces hypervisor isolation. The Pi's single ethernet cable is the equivalent of a guest's restricted network interface.

---

## Hardware Assumptions

- **Board**: Raspberry Pi 4 Model B (2 GB RAM minimum; 4 GB preferred)
- **PoE**: Official Raspberry Pi PoE+ HAT or equivalent; powered from ZyXEL GS1900-10HP switch
- **Bluetooth**: Onboard BCM43438 adapter (used for SwitchBot BLE scanning)
- **Storage**: No SD card in production. SD card required one-time only for EEPROM update to enable netboot
- **USB**: Reserved for Zigbee coordinator dongle when Zigbee2MQTT is enabled (future)
- **Network**: Single ethernet via PoE HAT; 1 Gbps

---

## Services

### 1. Mosquitto MQTT Broker (`services.mosquitto`)

**Purpose**: Central message bus for all IoT sensor data. All other services publish to or subscribe from this broker. Home Assistant and the NAS Prometheus exporter connect here as clients.

**Configuration requirements**:

- Listen on port `1883` (plain, LAN-only) and port `8883` (TLS)
- `persistence = false` — all retained messages live in RAM only; repopulate within one scan interval after reboot. This is intentional.
- Per-user ACLs enforced at the broker level:
  - `switchbot-scanner` — `readwrite switchbot/#`
  - `zigbee2mqtt` — `readwrite zigbee2mqtt/#` (future; disabled until Zigbee hardware present)
  - `exporter` — `read #` (read-only, all topics)
  - `homeassistant` — `readwrite homeassistant/#`, `read switchbot/#`, `read zigbee2mqtt/#`, `readwrite homeassistant/status`
- Passwords stored as hashed values via `hashedPasswordFile` pointing to sops-nix secrets
- TLS configuration: server certificate and key from sops-nix; CA certificate from local PKI on NAS
- WebSocket listener on port `9001` for Home Assistant browser-based clients (optional but recommended for Lovelace wall panel)
- `max_keepalive = 300`

**MQTT over TLS note**: Client certificate authentication is the target end state, replacing username/password ACLs. Each client (scanner, exporter, HA) presents a certificate signed by the local CA. The broker maps the certificate common name to ACL permissions. Private keys for client certificates must live only in RAM, decrypted at boot via sops-nix. This removes passwords from the equation entirely.

**Secrets required**:
- `mqtt/server-cert` — broker TLS certificate
- `mqtt/server-key` — broker TLS private key
- `mqtt/ca-cert` — local CA certificate
- `mqtt/hashed-password-scanner` — bcrypt hash for switchbot-scanner user
- `mqtt/hashed-password-exporter` — bcrypt hash for exporter user
- `mqtt/hashed-password-homeassistant` — bcrypt hash for homeassistant user

---

### 2. SwitchBot BLE Scanner (custom systemd service)

**Purpose**: Scans for SwitchBot Meter Plus BLE advertisement packets and publishes temperature, humidity, and battery readings to Mosquitto. This is the sole service that touches the Bluetooth hardware.

**Implementation**: Custom Python script using `python3Packages.pyswitchbot` (v0.76.0+, in nixpkgs). No non-nixpkgs dependencies required.

**Script behaviour**:

- Passive BLE scan only — the adapter receives advertisements but never transmits scan requests, connection attempts, or any other Bluetooth traffic
- Filter by known sensor MAC addresses (hardcoded in configuration; see custom code section)
- Identify SwitchBot Meter Plus by device model code in advertisement payload (not MAC alone)
- Publish to `switchbot/{MAC_without_colons}/state` with JSON payload:
  ```json
  {"temperature": 22.5, "humidity": 55, "battery": 95}
  ```
- Retain flag set on all published messages
- Optionally publish HA MQTT discovery messages to `homeassistant/sensor/switchbot_{mac}_{field}/config` at startup, enabling auto-discovery in Home Assistant without manual YAML
- Scan interval: configurable via environment variable, default 60 seconds
- Reconnect logic: exponential backoff on MQTT broker connection failure
- Graceful shutdown on SIGTERM

**systemd hardening** (all of the following must be applied):

```
DynamicUser = true
SupplementaryGroups = [ "bluetooth" ]
ProtectSystem = "strict"
ProtectHome = true
PrivateTmp = true
PrivateDevices = true
DeviceAllow = [ "char-bluetooth rw" ]
ProtectKernelTunables = true
ProtectKernelModules = true
ProtectKernelLogs = true
ProtectControlGroups = true
ProtectClock = true
ProtectHostname = true
ProtectProc = "invisible"
ProcSubset = "pid"
CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ]
AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ]
NoNewPrivileges = true
RestrictAddressFamilies = [ "AF_BLUETOOTH" "AF_INET" "AF_UNIX" ]
SystemCallFilter = [ "@system-service" "~@privileged" "~@raw-io" "~@reboot" "~@swap" "~@obsolete" ]
SystemCallArchitectures = "native"
LockPersonality = true
RestrictRealtime = true
RestrictSUIDSGID = true
RemoveIPC = true
UMask = "0077"
```

Note: `MemoryDenyWriteExecute` cannot be applied — Python's runtime breaks it.

**nftables egress restriction**: A kernel-level rule restricts this service's UID to outbound connections targeting only `{NAS_BRIDGE_IP}:1883` and `{NAS_BRIDGE_IP}:8883`. All other outbound TCP/UDP from this UID is dropped. This is the most meaningful network-level control available given Python's runtime limitations.

**Secrets required**:
- `mqtt/scanner-password` — MQTT password for switchbot-scanner user (or private key path for client cert auth)

**Service dependencies**:
- `After = [ "bluetooth.target" "mosquitto.service" "network-online.target" ]`
- `Wants = [ "bluetooth.target" "network-online.target" ]`

---

### 3. BlueZ Bluetooth Stack

**Purpose**: Provides the kernel Bluetooth interface consumed by the BLE scanner. Must be locked down to prevent use by any other service.

**Configuration requirements**:

```ini
# /etc/bluetooth/main.conf
[Policy]
AutoEnable = false

[LE]
EnableAdvMonitor = false
```

BlueZ daemon launched with all plugins disabled:

```
ExecStart = "${pkgs.bluez}/libexec/bluetooth/bluetoothd --noplugin=*"
```

This disables A2DP (audio), HID (keyboards/mice), and all other Bluetooth profiles. The adapter becomes a passive BLE advertisement receiver only. No pairing, no connections, no responses to other devices.

---

### 4. Prometheus MQTT Exporter (`services.prometheus.exporters.mqtt`)

**Purpose**: Subscribes to all Mosquitto topics, converts JSON payloads to Prometheus metrics, and exposes them on `:9000` for the NAS Prometheus instance to scrape.

**Configuration requirements**:

- Listen on `0.0.0.0:9000`
- `mqttAddress = "127.0.0.1"` (loopback; broker is on same host)
- `mqttPort = 1883`
- `mqttUsername = "exporter"`
- `mqttTopic = "#"` (all topics)
- `prometheusPrefix = "mqtt_"`
- `zigbee2MqttAvailability = true` (for future Zigbee devices)
- MQTT password via `environmentFile` pointing to a sops-nix template (the module does not accept direct secret paths)
- `openFirewall = false` — firewall rule added explicitly to allow NAS IP only

**Firewall rule**: Only the NAS Prometheus IP should be able to reach port 9000. All other sources dropped.

**Secrets required**:
- `mqtt/exporter-password` — MQTT password for exporter user

**Expected metric output for SwitchBot sensors**:
```
mqtt_temperature{topic="switchbot/AABBCCDDEE/state"} 22.5
mqtt_humidity{topic="switchbot/AABBCCDDEE/state"} 55
mqtt_battery{topic="switchbot/AABBCCDDEE/state"} 95
```

---

### 5. Zigbee2MQTT (`services.zigbee2mqtt`) — DEFERRED

**Status**: Deferred pending:
1. Purchase and installation of Zigbee devices (smart curtains)
2. Resolution of nixpkgs issue #439276 (evaluation failure in the zigbee2mqtt module on nixpkgs-unstable as of early 2026)
3. USB passthrough of Zigbee coordinator dongle (MotionBlinds or equivalent; likely Silicon Labs EFR32 / Ember adapter)

**When enabled, requirements**:
- `homeassistant.enabled = true` in Z2M config (enables HA MQTT auto-discovery)
- Discovery prefix must match HA (`homeassistant`)
- `permit_join = false` (default; enable temporarily when adding new devices)
- Serial port: `/dev/ttyUSB0` or `/dev/serial/by-id/...` (prefer by-id for stability)
- `After = [ "mosquitto.service" ]`
- Frontend disabled or LAN-only (access via HA or direct browser on LAN)

---

## Custom Code

### `switchbot-meter-mqtt.py`

Full specification for the BLE scanner script. This must be stored in the flake (e.g. `./modules/switchbot-meter-mqtt.py`) and referenced by path in the systemd service `ExecStart`.

**Inputs (via environment variables)**:

| Variable | Default | Description |
|---|---|---|
| `MQTT_HOST` | `127.0.0.1` | MQTT broker hostname or IP |
| `MQTT_PORT` | `1883` | MQTT broker port |
| `MQTT_USER` | `switchbot-scanner` | MQTT username |
| `MQTT_PASS` | _(required)_ | MQTT password |
| `MQTT_TLS` | `false` | Enable TLS (`true`/`false`) |
| `MQTT_CA_CERT` | — | Path to CA certificate (if TLS enabled) |
| `MQTT_CLIENT_CERT` | — | Path to client certificate (if mutual TLS) |
| `MQTT_CLIENT_KEY` | — | Path to client private key (if mutual TLS) |
| `SCAN_INTERVAL` | `60` | Seconds between BLE scans |
| `TOPIC_PREFIX` | `switchbot` | MQTT topic prefix |
| `KNOWN_SENSORS` | — | Comma-separated MAC addresses to accept; if unset, accept all SwitchBot Meter devices |
| `HA_DISCOVERY` | `true` | Publish HA MQTT discovery messages at startup |
| `HA_DISCOVERY_PREFIX` | `homeassistant` | HA discovery topic prefix |
| `LOG_LEVEL` | `INFO` | Logging verbosity |

**Behaviour specification**:

1. On startup, connect to MQTT broker with retry/backoff (initial 5s, max 60s, jitter)
2. If `HA_DISCOVERY=true`, publish retained discovery config messages for each known sensor's temperature, humidity, and battery entities
3. Enter scan loop:
   a. Call `GetSwitchbotDevices().discover(timeout=10)` (passive scan)
   b. Filter results: skip any device not in `KNOWN_SENSORS` (if set), skip any device whose model code does not match Meter / Meter Plus / Meter Pro (`T`, `i`, `e`)
   c. For each accepted device, publish retained JSON to `{TOPIC_PREFIX}/{mac_no_colons}/state`
   d. Sleep `SCAN_INTERVAL` seconds
4. Handle SIGTERM: disconnect MQTT cleanly, exit 0
5. Handle MQTT disconnect: reconnect with backoff, do not exit

**HA discovery payload example** (temperature sensor for one device):
```json
{
  "name": "SwitchBot Temperature AABBCCDDEE",
  "state_topic": "switchbot/AABBCCDDEE/state",
  "value_template": "{{ value_json.temperature }}",
  "unit_of_measurement": "°C",
  "device_class": "temperature",
  "unique_id": "switchbot_AABBCCDDEE_temperature",
  "device": {
    "identifiers": ["switchbot_AABBCCDDEE"],
    "name": "SwitchBot Meter AABBCCDDEE",
    "model": "Meter Plus",
    "manufacturer": "SwitchBot"
  }
}
```

Repeat for `humidity` (`%`, device_class `humidity`) and `battery` (`%`, device_class `battery`).

---

## Networking

### Bridge Network

The Pi sits on the same LAN as the NAS. It receives a static IP lease from Kea DHCP based on its MAC address, outside the PXE client class (the PXE options are only sent to the Pi's MAC for netboot purposes; regular DHCP behaviour is otherwise unchanged).

**Recommended static assignment**: `192.168.x.y` — specific address to be determined by the operator's LAN schema.

**systemd-networkd configuration**:

```nix
systemd.network.enable = true;
systemd.network.networks."10-lan" = {
  matchConfig.Name = "en*";
  addresses = [{ Address = "192.168.x.y/24"; }];  # static
  routes = [{ Gateway = "192.168.x.1"; }];
  dns = [ "192.168.x.1" ];
};
```

### Firewall (nftables)

The Pi's firewall should be restrictive by default with explicit allowances:

**Inbound**:
- Port `1883` (MQTT): allow from LAN subnet only
- Port `8883` (MQTT/TLS): allow from LAN subnet only
- Port `9001` (MQTT WebSocket): allow from LAN subnet only (optional)
- Port `9000` (Prometheus exporter): allow from NAS IP only
- Port `22` (SSH): allow from trusted admin IPs only; consider disabling after netboot is confirmed stable
- All other inbound: drop

**Outbound** (per-UID egress restrictions via nftables mark or owner match):
- `switchbot-scanner` UID: allow TCP to `{NAS_IP}:1883` and `{NAS_IP}:8883` only; drop all else
- `mosquitto` UID: allow outbound TCP on 1883/8883 for client connections from LAN; no arbitrary outbound
- `mqtt-exporter` UID: allow TCP to `127.0.0.1:1883` only
- All other UIDs: allow outbound to LAN and DNS; block internet egress

Note: `DynamicUser = true` allocates a non-deterministic UID. Use `User = "switchbot-scanner"` (static user) for the scanner service to enable precise UID-based nftables rules.

---

## Secrets Management

### Architecture: sops-nix + Tang/Clevis

All secrets are encrypted with age keys managed by sops-nix. The Pi's age private key is never written to persistent storage.

**Boot-time secret decryption flow**:

1. Pi's initrd boots over the network (TFTP/NFS)
2. Clevis in the initrd contacts the Tang server on the NAS
3. Clevis completes a cryptographic key exchange (no secret stored server-side; Tang cannot reconstruct the key alone)
4. The age private key is reconstructed and held in RAM
5. sops-nix uses the age key to decrypt `secrets/pi.yaml` into `/run/secrets/` (tmpfs)
6. Services start, reading secrets from `/run/secrets/`

**If Pi is removed from the network**: Tang is unreachable → Clevis cannot reconstruct the age key → secrets cannot be decrypted → Pi cannot fully boot. Physical theft of the Pi yields nothing.

**Tang server**: Runs on the NAS as `services.tang` (nixpkgs). Minimal attack surface (small C program, stores no client secrets).

### `.sops.yaml` Structure

```yaml
creation_rules:
  - path_regex: secrets/pi\.yaml$
    key_groups:
      - age:
          - age1pi_public_key_here
  - path_regex: secrets/host\.yaml$
    key_groups:
      - age:
          - age1nas_public_key_here
```

### `secrets/pi.yaml` Contents

| Key | Description |
|---|---|
| `mqtt/server-cert` | Broker TLS certificate |
| `mqtt/server-key` | Broker TLS private key |
| `mqtt/ca-cert` | Local CA certificate |
| `mqtt/hashed-password-scanner` | Mosquitto hashed password for scanner user |
| `mqtt/hashed-password-exporter` | Mosquitto hashed password for exporter user |
| `mqtt/hashed-password-homeassistant` | Mosquitto hashed password for HA user |
| `mqtt/scanner-password` | Plaintext password for scanner MQTT client (or client cert key) |
| `mqtt/exporter-password` | Plaintext password for exporter MQTT client |

### sops-nix Templates

The Prometheus MQTT exporter requires an environment file rather than a direct secret reference. Declare a sops template:

```nix
sops.templates."mqtt-exporter-env" = {
  content = ''
    MQTT_PASSWORD=${config.sops.placeholder."mqtt/exporter-password"}
  '';
};
```

The scanner service similarly receives credentials via `EnvironmentFile` pointing to a sops template.

---

## Netboot Requirements

### Current State: SD Card Boot

Initial deployment uses an SD card. The netboot path is deferred until the SD card setup is confirmed stable and the NAS-side TFTP/NFS infrastructure is in place.

### Target State: Full Netboot, No SD Card

**EEPROM configuration** (one-time, requires SD card):

Set boot order to network-first, then USB, skip SD:
```
BOOT_ORDER=0xf21  # SD → USB → Network (for testing with SD still present)
BOOT_ORDER=0xf2   # USB → Network (production, no SD card)
```

Apply via `rpi-eeprom-config --apply` with a config file specifying the boot order. After this change the SD card can be removed permanently.

**NAS-side requirements**:

| Service | Purpose | NixOS module |
|---|---|---|
| Kea DHCP | PXE options for Pi MAC address | `services.kea.dhcp4` |
| TFTP server | Serves kernel, initrd, device tree | `services.atftpd` or `services.tftp-hpa` |
| NFS export | Serves Pi's Nix store closure read-only | `services.nfs.server` |
| Tang server | Network-bound secret decryption at boot | `services.tang` |

**Kea DHCP client class** (add to existing Kea config, does not affect other clients):

```json
{
  "client-classes": [{
    "name": "raspberry-pi-iot-hub",
    "test": "hexstring(pkt4.mac, ':') == 'dc:a6:32:xx:xx:xx'",
    "option-data": [
      { "name": "tftp-server-name", "data": "192.168.x.nas" },
      { "name": "boot-file-name", "data": "bootcode.bin" }
    ]
  }]
}
```

**NixOS netboot module** (`netboot.nix`):

The Pi's NixOS configuration must include `(import <nixpkgs/nixos/modules/installer/netboot/netboot.nix>)` or equivalent. This generates the kernel, initrd, and squashfs store that TFTP serves.

**Root filesystem**: The Pi mounts its Nix store read-only over NFS from the NAS. Writable directories (`/tmp`, `/run`, `/var`) are tmpfs in RAM. Nothing is written to any persistent storage during normal operation.

**Clevis in initrd**: The initrd must include Clevis and its dependencies. This requires custom initrd configuration in the NixOS module:

```nix
boot.initrd.extraUtilsCommands = ''
  copy_bin_and_libs ${pkgs.clevis}/bin/clevis
  copy_bin_and_libs ${pkgs.jose}/bin/jose
  copy_bin_and_libs ${pkgs.curl}/bin/curl
'';
```

Or use the `boot.initrd.clevis` options if available in the nixpkgs version in use. The initrd script must contact Tang, reconstruct the age key, and make it available to sops-nix's activation script before services start.

**State persistence**: Nothing on the Pi needs to survive a reboot. After a reboot:
- Mosquitto repopulates retained messages within one scan interval (~60 seconds)
- The scanner reconnects to the broker and resumes publishing
- sops-nix re-decrypts secrets from the age key reconstructed by Clevis

---

## NixOS Module Structure

Suggested layout within the flake:

```
flake.nix
hosts/
  pi-iot/
    default.nix          # Top-level host config, imports all modules
    hardware.nix         # Pi 4 hardware, PoE HAT, aarch64 config
    networking.nix       # Static IP, firewall, nftables egress rules
    bluetooth.nix        # BlueZ lockdown configuration
    mqtt.nix             # Mosquitto broker config
    scanner.nix          # switchbot-scanner systemd service
    exporter.nix         # Prometheus MQTT exporter
    netboot.nix          # Netboot-specific config (NFS root, initrd, Clevis)
    secrets.nix          # sops-nix declarations
  nas/
    tang.nix             # Tang server
    kea-pxe.nix          # PXE client class additions to Kea
    nfs-exports.nix      # NFS export of Pi store
    tftp.nix             # TFTP server for Pi boot files
modules/
  switchbot-meter-mqtt.py   # BLE scanner script
secrets/
  pi.yaml                   # sops-encrypted Pi secrets
  host.yaml                 # sops-encrypted NAS secrets (includes Pi age key)
.sops.yaml
```

**`flake.nix` inputs required**:

```nix
inputs = {
  nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  # nixos-unstable required for recent Pi 4 hardware support and services.tang
  nixos-hardware.url = "github:nixos/nixos-hardware";
  sops-nix = {
    url = "github:Mic92/sops-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
```

**`hardware.nix` must include**:

```nix
imports = [
  nixos-hardware.nixosModules.raspberry-pi-4
];
# aarch64-linux system
# GPU memory split: minimal (16MB) — no display output needed
# PoE HAT fan control if supported by the HAT revision
```

---

## Python Version and Dependency Notes

- `python3Packages.pyswitchbot` tracks the version used by Home Assistant core and is actively maintained
- `python3Packages.paho-mqtt` is the MQTT client library used by the scanner script
- Both are in nixpkgs; no pip installation or non-nixpkgs dependencies required
- The scanner service's Python environment is declared as:

```nix
path = [
  (pkgs.python3.withPackages (ps: with ps; [ pyswitchbot paho-mqtt ]))
];
```

---

## Known Issues and Deferred Items

| Item | Status | Notes |
|---|---|---|
| nixpkgs #439276 (zigbee2mqtt eval failure) | Open as of early 2026 | Block on enabling Zigbee2MQTT; monitor for fix |
| Clevis in NixOS initrd on aarch64 | Requires testing | Less community documentation than x86; validate before removing SD card |
| nftables UID-based egress with DynamicUser | Requires static user | Switch scanner service to `User = "switchbot-scanner"` with a declared `users.users` entry |
| MQTT over TLS with client certificates | Future | Replace username/password ACLs once local CA is established on NAS |
| Zigbee2MQTT USB passthrough | Future | Requires Zigbee coordinator dongle and device purchase decision |
| Home Assistant MQTT user ACLs | Future | HA connects as `homeassistant` user; ACL scope to be tightened once HA topics are fully known |
| SD card → full netboot migration | Deferred | Boot from SD first; validate all services; then configure EEPROM and migrate to netboot |

---

## Security Properties Summary

| Property | Implementation |
|---|---|
| Physical isolation | Dedicated hardware; no shared kernel or filesystem with NAS |
| No persistent writable storage | Netboot target: NFS read-only root, all writes to tmpfs |
| Secret protection at rest | Tang/Clevis: secrets undecryptable without LAN access to Tang server |
| Secret protection in memory | sops-nix: age key held in RAM only; decrypted secrets in tmpfs `/run/secrets/` |
| Service confinement | systemd hardening on all services; DynamicUser; capability bounding sets |
| Network egress restriction | nftables per-UID rules; each service limited to its required destinations only |
| Bluetooth lockdown | BlueZ with `--noplugin=*`; passive scan only; `RestrictAddressFamilies` on scanner |
| Blast radius | Full Pi compromise yields: MQTT credentials (sensor data access only); no path to NAS data or other LAN services |
| BLE sensor data confidentiality | Not provided — SwitchBot Meter Plus broadcasts unencrypted BLE advertisements. Physical proximity is the only barrier. Data is non-sensitive (ambient temperature/humidity). This is an accepted, intentional limitation of the device choice. |

## Correction — Section "EEPROM configuration"

The spec describes two EEPROM changes: first setting BOOT_ORDER=0xf21 for testing, then changing to BOOT_ORDER=0xf2 for production once the SD card is removed. The second change is unnecessary and should be removed from the spec.
The Pi 4's default boot order does not include network boot, so one EEPROM update is required to add it to the sequence. Setting 0xf21 (SD → USB → Network) is sufficient for both the testing phase and production. Once the SD card is physically removed, the Pi will attempt SD boot, find nothing, and fall through to network boot automatically. The EEPROM has no awareness of whether an SD card is physically present — it simply tries each option in order and continues when nothing responds.
The 0xf2 production change described in the spec is therefore redundant and introduces an unnecessary second write to the EEPROM. Remove the BOOT_ORDER=0xf2 step and the associated note about a second EEPROM update. The single 0xf21 update performed during initial setup is the only EEPROM change required for the lifetime of the device.
