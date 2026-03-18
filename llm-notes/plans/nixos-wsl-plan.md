# NixOS-WSL Workstation Plan

## Context

Configure a NixOS-WSL instance on the Windows desktop as a managed flake host. This is a
**client workstation**, not a server — it consumes infrastructure services (SSH certificates,
DNS, git) rather than providing them. It will be the first WSL host in the flake.

The Windows machine is already on the home network and can reach internal services.

## Goals

1. Add a NixOS-WSL host to the flake (`nixosConfigurations`)
2. Integrate home-manager for user environment (dev tools, shell, editor)
3. Configure SSH certificate authentication to homelab hosts
4. Trust the internal CA (step-ca) for TLS
5. Register the host's SSH public key in `keys.json` for authorized access

## Non-goals

- Managing Windows itself (only the WSL environment)
- Impermanence (WSL has a persistent filesystem by default)
- sops-nix secrets (no secrets to decrypt on a workstation — SSH certs are obtained at runtime)
- Firewall configuration (WSL networking is managed by Windows)
- Network registry entry (this is a client, not a server with a static IP)

---

## Prerequisites

- Windows 10/11 with WSL2 enabled (`wsl --install --no-distribution` from PowerShell)
- WSL version >= 2.4.4 (for `.wsl` file double-click install)
- NixOS-WSL tarball downloaded from https://github.com/nix-community/NixOS-WSL/releases
- Network access to internal services (DNS via phantasma, step-ca via basel)

### Initial NixOS-WSL installation

```powershell
# Install the NixOS distribution (double-click nixos.wsl or):
wsl --install --from-file nixos.wsl

# Launch it
wsl -d NixOS

# Inside WSL: set password and update channels for initial bootstrap
passwd
sudo nix-channel --update

# Make NixOS the default WSL distro
wsl -s NixOS
```

After the initial bootstrap, all subsequent config is managed via the flake.

---

## Step 1: Add NixOS-WSL flake input

**File:** `flake.nix`

Add the NixOS-WSL input:

```nix
nixos-wsl = {
  url = "github:nix-community/NixOS-WSL/main";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Pass it through the `outputs` function parameters.

---

## Step 2: Create host configuration

**Directory:** `hosts/<name>/` — use a Trails "legendary weapons" name per `docs/hostnames.md`
(desktops use that convention: kernviter, blutgang, bolverk).

### `hosts/<name>/default.nix`

```nix
{ config, pkgs, lib, ... }: {
  wsl = {
    enable = true;
    defaultUser = "mutantmell";
  };

  networking.hostName = "<name>";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
  };

  users.users.mutantmell = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    uid = 1000;
  };

  # SSH certificate client (shared module with laptop)
  common.ssh-cert-client.enable = true;

  # No sshd needed — this is a client-only machine
  # common.openssh is NOT enabled (no inbound SSH)

  time.timeZone = "UTC";
  system.stateVersion = "25.11";
}
```

---

## Step 3: Add flake output

**File:** `flake.nix`

```nix
<name> = self.lib.mk-nixos {
  inherit nixpkgs;
  system = "x86_64-linux";
  modules = [
    nixos-wsl.nixosModules.default
    home-manager.nixosModules.home-manager
    ./hosts/<name>
  ];
};
```

Note: `mk-nixos` already provides overlays, `common`, `promtail-client`, `sops-nix`, and
`impermanence` modules. All are opt-in (guarded by `mkIf cfg.enable`), so they won't
interfere. `promtail-client` could optionally be enabled to ship WSL logs to Loki.

---

## Step 4: SSH certificate client module

The SSH certificate client config is shared between this WSL host and the laptop (see
`nixos-laptop-plan.md`). Both need the same setup: step-cli, TLS trust, SSH client config,
and host CA trust.

### Create `modules/common/ssh-cert-client.nix`

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.common.ssh-cert-client;
  data = pkgs.mmell.lib.data;
  rootCaFingerprint = builtins.hashFile "sha256" data.pki.root;
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

    # step-cli defaults: CA URL, fingerprint, and default provisioner
    # This replaces the manual `step ca bootstrap` step and ensures
    # `step ssh login admin` uses keycloak without prompting.
    environment.etc."step-cli/defaults.json".text = builtins.toJSON {
      ca-url = "https://basel.internal";
      fingerprint = rootCaFingerprint;
      root = "/etc/ssl/certs/ca-certificates.crt";
      provisioner = "keycloak";
    };

    # Point step-cli at the system-wide defaults
    environment.variables.STEPPATH = "/etc/step-cli";

    # SSH client: present certificates, trust host CA
    programs.ssh = {
      extraConfig = ''
        Host *.internal *.internal.mutantmell.net
          User root
          IdentityFile ~/.ssh/id_ed25519
          CertificateFile ~/.ssh/id_ed25519-cert.pub
      '';
      knownHosts."host-ca" = {
        hostNames = [ "*.internal" "*.internal.mutantmell.net" "*.mutantmell.net" ];
        publicKeyFile = data.pki.sshHostCA;
        certAuthority = true;
      };
    };
  };
}
```

Note: `modules/common/openssh.nix` also adds the `host-ca` knownHosts entry for server
hosts. The entries will merge — NixOS deduplicates `programs.ssh.knownHosts` by attribute
name. The `ssh-cert-client` module uses the same `"host-ca"` key so they don't conflict
if both are enabled on the same host.

The `STEPPATH` environment variable points step-cli at `/etc/step-cli/` where the
system-wide defaults live. This eliminates the manual `step ca bootstrap` step entirely.
The `provisioner = "keycloak"` default means `step ssh login admin` won't prompt for
provisioner selection.

Note: The `rootCaFingerprint` computation uses `builtins.hashFile` on the root CA
certificate. This needs to be verified against what step-ca expects — step-ca may
use a different fingerprint format (e.g., fingerprint of the DER-encoded certificate
vs the PEM file). If it doesn't match, the fingerprint can be hardcoded or computed
differently. Test with `step certificate fingerprint lib/common/data/pki/root_ca.crt`.

### Register in `modules/common/default.nix`

Add `./ssh-cert-client.nix` to the imports list.

### Login workflow

```bash
# Per-session: obtain SSH certificate (opens browser for Keycloak login)
step ssh login admin

# SSH uses the certificate automatically
ssh root@calvard.internal
```

No manual `step ca bootstrap` needed — the NixOS config provides all defaults.

---

## Step 5: Home-manager integration

Wire home-manager into the NixOS config for the `mutantmell` user:

```nix
home-manager = {
  useGlobalPkgs = true;
  useUserPackages = true;
  extraSpecialArgs = {
    home-conf = {
      user = "mutantmell";
      langs = [ "rust" ];
    };
  };
  users.mutantmell = import ../../home;
};
```

The NixOS module approach is simpler than standalone `homeConfigurations` for a
single-user WSL instance. `home-conf` is passed via `extraSpecialArgs` to match
what `home/default.nix` expects.

---

## Step 6: Register SSH public key

Add the WSL host's SSH public key to `lib/common/data/keys.json` so other hosts can
authorize it if needed:

```json
{
  "ssh": {
    "<name>": "ssh-ed25519 AAAA..."
  }
}
```

Generate the key on first boot or pre-generate and place it.

---

## Step 7: WSL-specific considerations

### DNS resolution

WSL typically inherits Windows DNS. For `.internal` names to resolve, either:

1. Configure Windows DNS to forward `.internal` queries to phantasma (preferred)
2. Add static entries to `/etc/hosts` via NixOS config using `mkExtraHosts`
3. Configure `systemd-resolved` with a forward zone for `.internal`

Option 3 is the most NixOS-native:

```nix
wsl.wslConf.network.generateResolvConf = false;

services.resolved = {
  enable = true;
  fallbackDns = [ "1.1.1.1" "8.8.8.8" ];
  extraConfig = ''
    [Resolve]
    DNS=10.97.11.21
    Domains=~internal ~internal.mutantmell.net
  '';
};
```

Note: Setting `generateResolvConf = false` disables WSL's auto-generated `/etc/resolv.conf`,
which means systemd-resolved handles all DNS. The `fallbackDns` setting ensures non-`.internal`
domains still resolve if phantasma is unreachable. Without this, losing connectivity to
phantasma would break all DNS resolution including public domains.

### Git configuration

The repo clone inside WSL should use the SSH certificate for push/pull to creil (Forgejo):

```nix
programs.git.extraConfig = {
  url."ssh://git@creil.internal".insteadOf = "https://creil.internal";
};
```

### Interop with Windows filesystem

WSL2 mounts Windows drives at `/mnt/c/`, `/mnt/d/`, etc. No special NixOS config needed.
Avoid storing the nix store or git repos on Windows mounts (9P is slow).

---

## Deployment

WSL doesn't use `deploy-nixos-anywhere.sh` — it's deployed from within WSL itself:

```bash
# Inside WSL, from the dotfiles repo:
sudo nixos-rebuild switch --flake .#<name>
```

Or from another machine:

```bash
nixos-rebuild switch --flake .#<name> --target-host mutantmell@<wsl-ip>
```

The WSL IP is NAT'd behind Windows, so local rebuild is more practical.

---

## Files Modified

| File                                 | Action                                        |
| ------------------------------------ | --------------------------------------------- |
| `flake.nix`                          | Add `nixos-wsl` input, add nixosConfiguration |
| `hosts/<name>/default.nix`           | New — WSL host config                         |
| `modules/common/ssh-cert-client.nix` | New — shared SSH cert client module           |
| `modules/common/default.nix`         | Add `./ssh-cert-client.nix` to imports        |
| `lib/common/data/keys.json`          | Add WSL SSH public key                        |

## Verification

1. `nix build .#nixosConfigurations.<name>.config.system.build.toplevel` — builds
2. `sudo nixos-rebuild switch --flake .#<name>` — deploys inside WSL
3. `step ssh login admin --provisioner keycloak` — obtains SSH certificate
4. `ssh root@calvard.internal` — connects with certificate (no password, no TOFU)
