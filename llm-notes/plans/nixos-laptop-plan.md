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

**Directory:** `hosts/angbar/` — needs a Trails-themed name.

### `hosts/angbar/default.nix`

```nix
{ config, pkgs, lib, ... }: {
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "angbar";

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

### `hosts/angbar/hardware-configuration.nix`

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

## Step 5: SSH certificate client setup — DONE

### 5a. Shared SSH cert client module — ALREADY EXISTS

`modules/common/ssh-cert-client.nix` was created as part of the NixOS-WSL work.
The laptop just needs `common.ssh-cert-client.enable = true` in its host config.

### 5b. SSH certificate workflow

The day-to-day SSH workflow on the laptop:

```bash
# Per-session: obtain a short-lived SSH certificate (opens browser to Keycloak)
step ssh login admin
# -> Authenticates via Keycloak OIDC (password + MFA)
# -> step-ca signs a 12h SSH certificate
# -> Written to ~/.ssh/id_ed25519-cert.pub

# SSH connections use the certificate automatically
ssh root@calvard.internal
ssh root@edith.internal
```

No manual `step ca bootstrap` needed — the NixOS config provides all defaults.

The certificate is valid for 12 hours. After expiry, run `step ssh login admin` again.

### 5c. DNS resolution for `.internal` names

When on the home WiFi, DHCP-provided DNS (phantasma) resolves `.internal` names
automatically. No special config needed.

When connected remotely via WireGuard (see Step 6), DNS queries for `.internal` are
routed through the tunnel to phantasma.

---

## Step 6: WireGuard VPN — BLOCKED (thebeyond hardware)

Static WireGuard tunnel to the homelab for remote access. Connects to the `wg-vpn`
interface on thebeyond (NixOS router). **Blocked until thebeyond has hardware and is
deployed** — the router owns the WireGuard endpoint and peer config.

```nix
# hosts/angbar/wireguard.nix
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

### Zone access: RESOLVED

The `wg-vpn` interface has been merged into the `lab` zone (VLAN 21) as part of the
vLAB zone implementation. edith is now on the lab zone too, so VPN → edith is
intra-zone traffic — no cross-zone rules needed.

- On home WiFi: laptop is in `trusted` zone, which has `accessTo` including `lab`
- Over VPN: laptop is in `lab` zone (via wg-vpn), edith is also `lab` — same zone
- Lab zone policy: `accessTo = ["management" "lab" "dmz" "external"]`

See `done/vlab-zone-plan.md` for the full implementation details.

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
angbar = self.lib.mk-nixos {
  inherit nixpkgs;
  system = "x86_64-linux";
  modules = [
    nixos-hardware.nixosModules.lenovo-thinkpad-x1-7th-gen
    disko.nixosModules.disko  # only if using disko
    home-manager.nixosModules.home-manager
    ./hosts/angbar
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
5. `nixos-install --flake /path/to/dotfiles#angbar`
6. Reboot

### Option B: nixos-anywhere (if disko profile is used)

```bash
# From another machine on the network, with the laptop booted into the installer:
nix run github:nix-community/nixos-anywhere -- \
  --flake .#angbar \
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
    "angbar": "ssh-ed25519 AAAA..."
  }
}
```

### Register WireGuard public key on the router

Add the laptop's WG public key to the router's `wg-vpn` peer list.

### Test full workflow

No `step ca bootstrap` needed — the `ssh-cert-client` module provides all defaults.

```bash
# Obtain SSH certificate
step ssh login admin

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

| File                                           | Action                              | Status                       |
| ---------------------------------------------- | ----------------------------------- | ---------------------------- |
| `modules/common/ssh-cert-client.nix`           | Shared SSH cert client module       | DONE                         |
| `modules/common/default.nix`                   | `./ssh-cert-client.nix` in imports  | DONE                         |
| `flake.nix`                                    | Add nixosConfiguration + homeConfig | DONE                         |
| `hosts/angbar/default.nix`                     | New — laptop host config            | DONE                         |
| `hosts/angbar/hardware-configuration.nix`      | Stub — replaced at install time     | DONE (stub)                  |
| `home/graphical.nix`                           | Expand with sway desktop packages   | DONE                         |
| `hosts/calvard/incus/guests/edith/default.nix` | Add ET server                       | DONE                         |
| `hosts/angbar/wireguard.nix`                   | New — WireGuard VPN config          | BLOCKED (thebeyond hardware) |
| `lib/common/data/keys.json`                    | Add laptop SSH public key           | POST-INSTALL                 |

## Verification

1. `nix build .#nixosConfigurations.angbar.config.system.build.toplevel` — builds
2. NixOS boots on the ThinkPad with working sway, WiFi, trackpad
3. `step ssh login admin --provisioner keycloak` — obtains SSH certificate
4. `ssh root@edith.internal` — connects with certificate (no password, no TOFU)
5. `et edith.internal` — session-resilient connection works
6. Power management: battery life reasonable, S3 suspend/resume works
7. WireGuard: `wg-quick up wg-vpn` connects, `.internal` names resolve remotely
