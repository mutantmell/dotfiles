# NixOS Laptop (ThinkPad X1 Carbon 7th Gen) Plan

## Context

Install NixOS on a Lenovo ThinkPad X1 Carbon 7th Gen as the first full "device"
(end-user machine) managed by this flake. This machine acts primarily as a **thin client**
into the homelab — computation, state, and sessions live on edith (Incus dev env on
calvard). The laptop provides keyboard, display, WiFi, and a Wayland compositor.

Unlike the server hosts (thebeyond, calvard, erebonia, remiferia), this is a portable
workstation with a graphical environment, power management, and WiFi. Unlike WSL, this
is a standalone NixOS installation that owns the entire machine.

This establishes the pattern for how personal devices are configured in the flake —
separate from server infrastructure but sharing home-manager, SSH certificate auth,
and the project overlay.

## Goals

1. Install NixOS on the ThinkPad with full hardware support
2. Add it as a `nixosConfigurations` entry using `mk-nixos`
3. Integrate home-manager for user environment (graphical + dev tools)
4. Configure SSH certificate authentication to homelab hosts
5. Trust the internal CA (step-ca) for TLS
6. Configure WiFi, power management, and laptop-specific features
7. Full-disk encryption with LUKS
8. WireGuard VPN for remote access to homelab
9. Session-resilient terminal connection to edith

## Non-goals

- Impermanence (use a standard persistent filesystem for a personal laptop)
- sops-nix secrets (no server secrets to decrypt)
- Network registry entry (mobile device, no static IP)
- Microvm/Incus hosting
- Managing the device via deploy-rs (laptop is self-managed)
- Syncthing / file sync (separate future concern)

---

## Step 1: Hardware support via nixos-hardware

The `nixos-hardware` flake input already exists in `flake.nix`. The relevant module:

```nix
nixos-hardware.nixosModules.lenovo-thinkpad-x1-7th-gen
```

This provides:

- Parent ThinkPad/Lenovo common config (trackpad, ACPI, etc.)
- SSD optimizations (TRIM, scheduler)
- `services.throttled` for thermal management (Intel throttling fix)

---

## Step 2: Create host configuration

**Directory:** `hosts/<name>/` — needs a Trails-themed name.

### `hosts/<name>/default.nix`

```nix
{ config, pkgs, lib, ... }: {
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "<name>";

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = [ "mem_sleep_default=deep" ];  # reliable S3 sleep on Gen 7

  # Networking
  networking.networkmanager.enable = true;  # wpa_supplicant backend (default)

  # Locale
  time.timeZone = "America/New_York";  # adjust as needed
  i18n.defaultLocale = "en_US.UTF-8";

  # Nix
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
  };

  # User
  users.users.mutantmell = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    uid = 1000;
  };

  # SSH certificate client
  common.ssh-cert-client.enable = true;

  # Power management
  services.thermald.enable = true;
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
    };
  };

  # Audio
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # Bluetooth
  hardware.bluetooth.enable = true;

  # Firmware updates
  services.fwupd.enable = true;

  # Fonts
  fonts.packages = [ pkgs.jetbrains-mono ];

  system.stateVersion = "25.11";
}
```

### `hosts/<name>/hardware-configuration.nix`

Generated at install time via `nixos-generate-config`. Will contain:

- Kernel modules for the X1 Carbon (Intel GPU `i915`, WiFi `iwlwifi`, NVMe, etc.)
- Filesystem declarations (LUKS + ext4/btrfs)
- EFI system partition

---

## Step 3: Disk layout and encryption

The X1 Carbon 7th Gen has a single NVMe drive. Use LUKS full-disk encryption.

### Option A: Manual partitioning at install time

Standard NixOS install process — partition, format, mount, then `nixos-install --flake`.
`hardware-configuration.nix` captures the result.

### Option B: Disko profile

Create a laptop disko profile for repeatable installs:

```nix
# profiles/disko/laptop.nix
{ disk ? "/dev/nvme0n1", ... }: {
  disko.devices.disk.main = {
    device = disk;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            settings.allowDiscards = true;
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
```

Decision deferred to implementation time — Option A is simpler for a one-off device.

---

## Step 4: Desktop environment

### Compositor: Sway

Sway is a Wayland tiling compositor — lightweight, keyboard-driven, and well-suited
to a thin client where most work happens in a terminal.

```nix
# NixOS-level: handles polkit, XDG portals, GTK wrapping
programs.sway.enable = true;
```

### Display manager: greetd + tuigreet

Minimal console-based greeter. No full display manager needed for a single-user machine.

```nix
services.greetd = {
  enable = true;
  settings.default_session = {
    command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd sway";
    user = "greeter";
  };
};
```

### Terminal: foot

Native Wayland terminal with server/client architecture for fast window spawning.

```nix
# via home-manager
programs.foot = {
  enable = true;
  settings.main = {
    font = "JetBrains Mono:size=11";
  };
};
```

### Screen lock: swaylock + swayidle

```nix
# via home-manager
programs.swaylock.enable = true;
services.swayidle.enable = true;
```

### Night mode: gammastep

```nix
# via home-manager
services.gammastep = {
  enable = true;
  provider = "manual";
  latitude = 40.0;   # adjust
  longitude = -74.0;  # adjust
};
```

### Status bar

`swaybar` with `i3status` (built into sway), or no bar at all. Decision deferred to
implementation — easy to add/remove.

### Sway configuration location

Sway config is managed declaratively via home-manager's
`wayland.windowManager.sway.config` and generates `~/.config/sway/config`.

```nix
# via home-manager
wayland.windowManager.sway = {
  enable = true;
  config = {
    terminal = "foot";
    modifier = "Mod4";  # Super key
    fonts = {
      names = [ "JetBrains Mono" ];
      size = 11.0;
    };
    input."type:touchpad" = {
      tap = "enabled";
      natural_scroll = "enabled";
    };
    # output."*".scale = "1.5";  # uncomment for WQHD display
    keybindings = let
      mod = "Mod4";
    in {
      "${mod}+Return" = "exec foot";
      "${mod}+d" = "exec ${pkgs.wmenu}/bin/wmenu-run";
      "${mod}+Shift+q" = "kill";
      "${mod}+Shift+e" = "exec swaymsg exit";
      # ... standard i3/sway keybindings
    };
    bars = [{
      statusCommand = "${pkgs.i3status}/bin/i3status";
    }];
  };
};
```

### Home-manager graphical module

The existing `home/graphical.nix` only enables Firefox. It needs to be expanded:

```nix
# home/graphical.nix additions:
# - sway compositor config (wayland.windowManager.sway)
# - foot terminal
# - swaylock + swayidle
# - gammastep
# - waypipe (Wayland app forwarding over SSH)
# - Zed editor
# - nano (fallback editor)
```

The `home-conf.is-graphical = true` flag imports this module.

---

## Step 5: SSH certificate client setup

### 5a. Shared SSH cert client module

Since both WSL and the laptop need the same SSH certificate client config, create a
shared common module:

**File:** `modules/common/ssh-cert-client.nix`

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.common.ssh-cert-client;
  data = pkgs.mmell.lib.data;
in {
  options.common.ssh-cert-client = {
    enable = lib.mkEnableOption "SSH certificate client configuration";
  };

  config = lib.mkIf cfg.enable {
    # step-cli for obtaining certificates
    environment.systemPackages = [ pkgs.step-cli ];

    # Trust the internal root CA for TLS (so step-cli, curl, etc.
    # can reach https://basel.internal without --insecure)
    security.pki.certificateFiles = [ data.pki.root ];

    # SSH client: present certificates, trust host CA
    programs.ssh = {
      extraConfig = ''
        Host *.internal *.internal.mutantmell.net
          User root
          IdentityFile ~/.ssh/id_ed25519
          CertificateFile ~/.ssh/id_ed25519-cert.pub
      '';
      knownHosts."internal-ca" = {
        hostNames = [ "*.internal" "*.internal.mutantmell.net" ];
        publicKeyFile = data.pki.sshHostCA;
        certAuthority = true;
      };
    };
  };
}
```

Both the WSL host and the laptop set `common.ssh-cert-client.enable = true`.

**Important:** `modules/common/default.nix` uses an explicit imports list, not
auto-discovery. `./ssh-cert-client.nix` must be added to the imports in that file.

### 5b. SSH certificate workflow

The day-to-day SSH workflow on the laptop:

```bash
# One-time: bootstrap step-cli trust store
step ca bootstrap --ca-url https://basel.internal --fingerprint <ROOT_CA_FINGERPRINT>

# Per-session: obtain a short-lived SSH certificate (opens browser to Keycloak)
step ssh login admin --provisioner keycloak
# -> Authenticates via Keycloak OIDC (password + MFA)
# -> step-ca signs a 12h SSH certificate
# -> Written to ~/.ssh/id_ed25519-cert.pub

# SSH connections use the certificate automatically
ssh root@calvard.internal
ssh root@edith.internal
```

The certificate is valid for 12 hours. After expiry, run `step ssh login` again.

### 5c. DNS resolution for `.internal` names

When on the home WiFi, DHCP-provided DNS (phantasma) resolves `.internal` names
automatically. No special config needed.

When connected remotely via WireGuard (see Step 6), DNS queries for `.internal` are
routed through the tunnel to phantasma.

---

## Step 6: WireGuard VPN

Static WireGuard tunnel to the homelab for remote access. Connects to the `wg-vpn`
interface on the router.

```nix
# hosts/<name>/wireguard.nix
{ config, ... }: {
  networking.wg-quick.interfaces.wg-vpn = {
    privateKeyFile = "/etc/wireguard/private.key";  # generated manually, not in nix store
    address = [ "<assigned-wg-ip>/24" ];
    dns = [ "<phantasma-ip>" ];  # resolve .internal names over the tunnel

    peers = [{
      publicKey = "<router-wg-public-key>";
      endpoint = "<public-ip-or-ddns>:51820";
      allowedIPs = [ "10.97.0.0/16" "fdc6:55f2:0a5e::/48" ];
      persistentKeepalive = 25;
    }];
  };
}
```

**DNS over WireGuard** is critical: when connected remotely, `basel.internal` and
`auth.mutantmell.net` must resolve for the SSH certificate flow to work. The `dns`
field in `wg-quick` configures systemd-resolved to route queries through the tunnel.

**Note:** The WireGuard private key is generated manually and stored outside the nix
store (no sops-nix on this machine). The public key should be registered in the
router's WireGuard peer config.

### Zone access: vpn → edith

The `vpn` zone currently has `accessTo = ["management" "untrusted" "dmz"]`. edith is
on VLAN 20 (brHOME), zone `trusted`. **The vpn zone cannot reach edith.**

The vpn zone is intentionally restricted — it should not grant access to the full
home LAN (`trusted`), which contains personal devices (wife's laptop, work laptop,
friends' devices on guest). The whole point of the zone model is blast-radius
containment.

Options:

1. **New zone and VLAN (e.g., `lab` / vLAB)** — a dedicated zone for dev
   environments where untrusted code runs (edith, trista, future dev envs). The
   spec document explicitly calls out "minimal permissions, no access to secrets"
   for dev containers — this is a fundamentally different trust level from both
   infrastructure (step-ca, Keycloak) and personal devices (laptops, phones).
   The vpn zone would add `"lab"` to its `accessTo`. Trusted zone would
   also get access (so the laptop works on home WiFi too). The lab zone
   itself would have restricted access — internet egress for packages/updates,
   but no lateral movement to management or trusted.
   Requires: new VLAN tag, `mkVlanBridge` entry, zone definition, switch config,
   network registry entries, move edith + trista to the new VLAN/bridge.
2. **Move edith to management (VLAN 11)** — simpler, reuses existing infra. But
   edith runs untrusted code (AI workloads, experimental packages) and
   vINFRA hosts step-ca and Keycloak. A compromised edith with lateral access
   to the CA is a bad outcome.
3. **Add a targeted forward rule** — `vpn → trusted` scoped to edith's IP only.
   Keeps edith on vHOME but pokes a hole in zone boundaries. Sets a precedent
   for per-host exceptions.

**Recommendation: Option 1, with wg-vpn merged into the lab zone.**

The VPN client (your laptop running arbitrary code) and the dev environments
(running arbitrary code) share the same trust level. Placing `wg-vpn` in the
lab zone means vpn → edith is intra-zone traffic — no cross-zone rules
needed. The current `vpn` zone definition (`accessTo = ["management"
"untrusted" "dmz"]`) becomes the lab zone's policy, and the separate
`vpn` zone is eliminated.

The lab zone policy:

- `accessTo = ["management" "dmz"]` — reach basel/messeldam for SSH certs,
  creil for Forgejo, oracion for media. (Drop `"untrusted"` — no reason for
  dev envs to reach IoT/guest devices.)
- Internet egress for packages/updates
- Reachable from `trusted` (so the laptop works on home WiFi)
- No access to `trusted` (blast-radius containment for personal devices)

Future Headscale VPN (friends accessing game servers) is separate — it runs
on vDMZ with its own ACL policy and doesn't use `wg-vpn`.

Hosts affected: edith, trista, and `wg-vpn` interface move to the new zone.
Requires: new VLAN tag, `mkVlanBridge` entry, zone definition, switch config,
network registry updates, Incus bridge changes.

**Downside:** When on the home WiFi, the desktop (trusted/vHOME) and edith
(lab/vLAB) are on different VLANs, so traffic between them must
round-trip through the router instead of being switched directly. The
router is reached via 6GHz mesh backhaul (not wired), so each cross-VLAN
hop traverses the mesh twice (desktop → mesh → router → mesh → calvard).
Dedicated 6GHz backhaul keeps latency low in practice, but it's a real
increase compared to the current setup where edith on vHOME allows direct
L2 switching through the local AP/switch without touching the router.

This needs to be resolved before the thin client workflow works over VPN.
When on the home WiFi (laptop is in `trusted` zone), edith is reachable
regardless, since `trusted` has `accessTo` to all internal zones.

---

## Step 7: Session-resilient connection to edith

The primary workflow is SSHing to edith (Incus dev env on calvard) and working in tmux.
The connection must survive WiFi drops, laptop sleep, and network changes.

### Eternal Terminal (et)

Eternal Terminal maintains a persistent connection that automatically reconnects.
Unlike mosh, it supports SSH certificates natively and doesn't require UDP port
ranges.

**Laptop side:**

```nix
environment.systemPackages = [ pkgs.eternal-terminal ];
```

**edith side** (add to `hosts/calvard/incus/guests/edith/default.nix`):

```nix
services.eternal-terminal = {
  enable = true;
  port = 2022;  # default ET port
};
```

**Workflow:**

```bash
# Obtain SSH certificate (if expired)
step ssh login admin --provisioner keycloak

# Connect with session resilience
et edith.internal

# Inside edith: attach to tmux
tmux attach || tmux new
```

ET uses SSH for the initial handshake (which presents the certificate), then
maintains a persistent encrypted connection. Laptop sleep, WiFi changes, and
brief network drops are handled transparently.

**Fallback:** plain `ssh edith.internal` always works; you just lose auto-reconnect.

### Editors on the laptop

- **Emacs + TRAMP** — runs on the laptop, edits files on edith remotely via
  `/ssh:edith.internal:`. Multi-hop supported (`/ssh:calvard|ssh:edith:`).
  TRAMP uses the SSH config from the laptop, so certificates are presented
  automatically.

- **Zed Remote SSH** — runs on the laptop, installs a lightweight Rust server
  binary on edith. LSP, file access, and compilation happen server-side.
  Add `pkgs.zed-editor` to edith's system packages for the server component.

- **waypipe** — for occasional remote GUI apps: `waypipe ssh edith.internal app`.

---

## Step 8: Home-manager integration

Use the NixOS home-manager module with `home-conf` extraSpecialArgs:

```nix
home-manager = {
  useGlobalPkgs = true;
  useUserPackages = true;
  extraSpecialArgs = {
    home-conf = {
      user = "mutantmell";
      langs = [ "rust" ];
      is-graphical = true;
    };
  };
  users.mutantmell = import ../../home;
};
```

The `is-graphical = true` flag imports `home/graphical.nix`. This module needs to be
expanded from its current Firefox-only state to include: foot, swaylock, swayidle,
gammastep, waypipe, Zed, and nano.

---

## Step 9: Add flake output

**File:** `flake.nix`

```nix
<name> = self.lib.mk-nixos {
  inherit nixpkgs;
  system = "x86_64-linux";
  modules = [
    nixos-hardware.nixosModules.lenovo-thinkpad-x1-7th-gen
    disko.nixosModules.disko  # only if using disko
    home-manager.nixosModules.home-manager
    ./hosts/<name>
  ];
};
```

---

## Step 10: Installation

### Option A: Standard NixOS install

1. Boot the NixOS installer ISO (use the custom `installer-iso` from the flake, which
   has the deploy SSH key pre-authorized)
2. Partition and format the NVMe drive (LUKS + ext4)
3. Mount at `/mnt`, `nixos-generate-config --root /mnt`
4. Copy `hardware-configuration.nix` into the repo
5. `nixos-install --flake /path/to/dotfiles#<name>`
6. Reboot

### Option B: nixos-anywhere (if disko profile is used)

```bash
# From another machine on the network, with the laptop booted into the installer:
nix run github:nix-community/nixos-anywhere -- \
  --flake .#<name> \
  root@<installer-ip>
```

This is overkill for a one-off laptop install but demonstrates the capability.

---

## Step 11: Post-install setup

### Generate SSH key and WireGuard key

```bash
ssh-keygen -t ed25519
wg genkey | tee /etc/wireguard/private.key | wg pubkey
```

### Register in keys.json

Add the laptop's SSH public key to `lib/common/data/keys.json`:

```json
{
  "ssh": {
    "<name>": "ssh-ed25519 AAAA..."
  }
}
```

### Register WireGuard public key on the router

Add the laptop's WG public key to the router's `wg-vpn` peer list.

### Bootstrap step-cli

```bash
step ca bootstrap --ca-url https://basel.internal --fingerprint <ROOT_CA_FINGERPRINT>
```

### Test full workflow

```bash
# Obtain SSH certificate
step ssh login admin --provisioner keycloak

# Verify certificate-based SSH
ssh root@calvard.internal

# Test session-resilient connection to dev env
et edith.internal
# Inside edith:
tmux new -s dev
```

---

## Laptop-specific considerations

### HiDPI

The X1 Carbon 7th Gen has a 14" display, either 1080p or 1440p WQHD. If WQHD,
configure sway scaling:

```nix
# In sway config (home-manager)
wayland.windowManager.sway.config.output."*".scale = "1.5";
```

### Fingerprint reader

```nix
services.fprintd.enable = true;
# Enroll: fprintd-enroll
```

### Webcam

Works out of the box. No special config needed.

---

## Changes to edith (remote dev env)

edith needs a few additions to support the thin client workflow:

| Change                                        | File                                           |
| --------------------------------------------- | ---------------------------------------------- |
| Add `services.eternal-terminal.enable = true` | `hosts/calvard/incus/guests/edith/default.nix` |
| Add `pkgs.zed-editor` to system packages      | `hosts/calvard/incus/guests/edith/default.nix` |

---

## Files Modified

| File                                           | Action                                 |
| ---------------------------------------------- | -------------------------------------- |
| `flake.nix`                                    | Add nixosConfiguration for the laptop  |
| `hosts/<name>/default.nix`                     | New — laptop host config               |
| `hosts/<name>/wireguard.nix`                   | New — WireGuard VPN config             |
| `hosts/<name>/hardware-configuration.nix`      | New — generated at install time        |
| `modules/common/ssh-cert-client.nix`           | New — shared SSH cert client module    |
| `modules/common/default.nix`                   | Add `./ssh-cert-client.nix` to imports |
| `lib/common/data/keys.json`                    | Add laptop SSH public key              |
| `home/graphical.nix`                           | Expand with sway desktop packages      |
| `hosts/calvard/incus/guests/edith/default.nix` | Add ET server + Zed editor             |

## Verification

1. `nix build .#nixosConfigurations.<name>.config.system.build.toplevel` — builds
2. NixOS boots on the ThinkPad with working sway, WiFi, trackpad
3. `step ssh login admin --provisioner keycloak` — obtains SSH certificate
4. `ssh root@edith.internal` — connects with certificate (no password, no TOFU)
5. `et edith.internal` — session-resilient connection works
6. Power management: battery life reasonable, S3 suspend/resume works
7. WireGuard: `wg-quick up wg-vpn` connects, `.internal` names resolve remotely
