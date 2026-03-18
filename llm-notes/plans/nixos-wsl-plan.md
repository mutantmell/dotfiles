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

**Directory:** `hosts/device-wsl/` (or a Trails-themed name)

### `hosts/device-wsl/default.nix`

```nix
{ config, pkgs, lib, ... }: {
  wsl = {
    enable = true;
    defaultUser = "mutantmell";
  };

  networking.hostName = "device-wsl";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
  };

  users.users.mutantmell = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    uid = 1000;
  };

  # SSH certificate client configuration (see Step 4)
  # No sshd needed — this is a client-only machine

  time.timeZone = "UTC";
  system.stateVersion = "25.11";
}
```

### Naming decision

The existing naming convention uses Trails location names tied to host roles. WSL is a
special case — it's a development environment on a Windows host, not a standalone machine.
Options:

- Use a Trails name (consistent with other hosts)
- Use a descriptive name like `wsl-desktop` (clear purpose)

Decision deferred to implementation time.

---

## Step 3: Add flake output

**File:** `flake.nix`

```nix
device-wsl = self.lib.mk-nixos {
  inherit nixpkgs;
  system = "x86_64-linux";
  modules = [
    nixos-wsl.nixosModules.default
    home-manager.nixosModules.home-manager
    ./hosts/device-wsl
  ];
};
```

Note: `mk-nixos` already provides overlays, `common`, `promtail-client`, `sops-nix`, and
`impermanence` modules. All are opt-in (guarded by `mkIf cfg.enable`), so they won't
interfere. `promtail-client` could optionally be enabled to ship WSL logs to Loki.

---

## Step 4: SSH certificate client setup

This is the key integration point. The workstation needs to:

1. **Obtain short-lived SSH certificates** from step-ca via Keycloak OIDC
2. **Trust the host CA** so it can verify server identity without TOFU
3. **Present certificates** when connecting to homelab hosts

### 4a. Install step-cli

Add `step-cli` to the system or home-manager packages:

```nix
environment.systemPackages = [ pkgs.step-cli ];
```

### 4b. Trust the internal CA for TLS

step-ca's HTTPS endpoint uses a certificate signed by the internal root CA. The `step ca
bootstrap` command handles this, but it's a manual one-time step. Alternatively, add the
root CA to the system trust store declaratively:

```nix
security.pki.certificateFiles = [
  ../../lib/common/data/pki/root_ca.crt
];
```

This lets `step-cli` (and `curl`, etc.) trust `https://basel.internal` without `--insecure`.

### 4c. SSH client configuration

Configure SSH to present certificates and trust the host CA. This can be done via
home-manager's `programs.ssh` or via NixOS's `programs.ssh`:

```nix
programs.ssh.extraConfig = ''
  Host *.internal *.internal.mutantmell.net
    User root
    IdentityFile ~/.ssh/id_ed25519
    CertificateFile ~/.ssh/id_ed25519-cert.pub
'';
```

### 4d. Trust the host CA in known_hosts

Add the host CA public key so SSH verifies server identity via certificate:

```nix
programs.ssh.knownHosts = {
  "internal-ca" = {
    hostNames = [ "*.internal" "*.internal.mutantmell.net" ];
    publicKeyFile = ../../lib/common/data/pki/ssh_host_ca.pub;
    certAuthority = true;
  };
};
```

This eliminates TOFU prompts for all `*.internal` hosts (once host certificates are signed).

### 4e. Login workflow

After deployment, the user runs:

```bash
# One-time: bootstrap step-cli trust
step ca bootstrap --ca-url https://basel.internal --fingerprint <ROOT_CA_FINGERPRINT>

# Per-session: obtain SSH certificate (opens browser for Keycloak login)
step ssh login admin --provisioner keycloak

# SSH uses the certificate automatically
ssh root@calvard.internal
```

---

## Step 5: Home-manager integration

Wire home-manager into the NixOS config for the `mutantmell` user:

```nix
home-manager = {
  useGlobalPkgs = true;
  useUserPackages = true;
  users.mutantmell = import ../../home {
    # Reuse existing home-manager config
  };
};
```

Alternatively, use the standalone `homeConfigurations` output with `home-manager switch`.
The NixOS module approach is simpler for a single-user WSL instance.

**Decision point:** The existing `home/default.nix` expects a `home-conf` extraSpecialArgs
with `user`, `langs`, etc. The NixOS home-manager module passes different args. Options:

1. Use the standalone `homeConfigurations` approach (run `home-manager switch` separately)
2. Adapt the NixOS module integration to pass `home-conf` via `extraSpecialArgs`
3. Refactor `home/default.nix` to work in both contexts

Option 2 is the least disruptive:

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

---

## Step 6: Register SSH public key

Add the WSL host's SSH public key to `lib/common/data/keys.json` so other hosts can
authorize it if needed:

```json
{
  "ssh": {
    "device-wsl": "ssh-ed25519 AAAA..."
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
services.resolved = {
  enable = true;
  extraConfig = ''
    [Resolve]
    DNS=10.97.11.21
    Domains=~internal ~internal.mutantmell.net
  '';
};
```

Note: WSL2's `/etc/resolv.conf` management may conflict. Set `wsl.wslConf.network.generateResolvConf = false` if using systemd-resolved.

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
sudo nixos-rebuild switch --flake .#device-wsl
```

Or from another machine:

```bash
nixos-rebuild switch --flake .#device-wsl --target-host mutantmell@<wsl-ip>
```

The WSL IP is NAT'd behind Windows, so local rebuild is more practical.

---

## Files Modified

| File                              | Action                                      |
| --------------------------------- | ------------------------------------------- |
| `flake.nix`                       | Add `nixos-wsl` input, add nixosConfiguration |
| `hosts/device-wsl/default.nix`    | New — WSL host config                       |
| `lib/common/data/keys.json`       | Add WSL SSH public key                      |

## Verification

1. `nix build .#nixosConfigurations.device-wsl.config.system.build.toplevel` — builds
2. `sudo nixos-rebuild switch --flake .#device-wsl` — deploys inside WSL
3. `step ssh login admin --provisioner keycloak` — obtains SSH certificate
4. `ssh root@calvard.internal` — connects with certificate (no password, no TOFU)
