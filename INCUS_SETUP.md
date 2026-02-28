# Incus Container Management Module

Declarative Incus container management with automatic in-place updates.

## Overview

The `incus-manager` module provides fully declarative Incus container management:
- **Automatic image import** - Images built from your flake are auto-imported
- **Automatic instance creation** - Containers are created on first deploy
- **Automatic updates** - Running `nixos-rebuild switch` updates containers in-place
- **Minimal disruption** - Only changed services restart (tmux usually survives)

## Quick Start

### 1. Define Container Image Configuration

Create `containers/<name>/default.nix`:

```nix
{ pkgs, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  networking.hostName = "mycontainer";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Your configuration here
  environment.systemPackages = with pkgs; [ git vim ];

  system.stateVersion = "24.05";
}
```

### 2. Add Image to Flake

In `flake.nix`, add to `nixosConfigurations`:

```nix
mycontainer-image = self.lib.mk-nixos {
  inherit nixpkgs;
  system = "x86_64-linux";
  modules = [
    home-manager.nixosModules.home-manager
    ./containers/mycontainer
  ];
};
```

And to `packages` (in the x86_64-linux section):

```nix
mycontainer-image = mkContainerImage "mycontainer" self.nixosConfigurations.mycontainer-image;
```

### 3. Configure Host

In `hosts/<hostname>/incus.nix`:

```nix
{ config, pkgs, lib, ... }:
{
  incus-manager = {
    enable = true;

    storage = {
      driver = "zfs";  # or "dir", "btrfs", "lvm"
      pool = "default";
      source = "tank/incus";  # ZFS dataset path
    };

    networks.incusbr20 = {
      bridge = "br20";  # Use existing bridge
    };

    profiles.dev = {
      config = {
        "limits.cpu" = "4";
        "limits.memory" = "8GB";
      };
      devices.root = {
        path = "/";
        pool = "default";
        type = "disk";
        size = "50GB";
      };
    };

    containers.mycontainer = {
      image = "mycontainer";
      imagePackage = pkgs.mmell.mycontainer-image;
      profile = "dev";
      network = "incusbr20";
      autoUpdate = true;
      autoStart = true;
    };
  };
}
```

### 4. Import and Deploy

Add to host `default.nix`:

```nix
imports = [
  ./incus.nix
  # ... other imports
];
```

Then rebuild:

```bash
sudo nixos-rebuild switch
```

**That's it!** The module will:
1. Set up Incus with configured storage and networks
2. Import the container image
3. Create and start the instance
4. Update it in-place on future rebuilds

## What Happens on `nixos-rebuild switch`

1. **Image Import** - If image doesn't exist, it's automatically imported
2. **Instance Creation** - If instance doesn't exist, it's created from the image
3. **Instance Start** - If autoStart is enabled and instance isn't running, it starts
4. **In-Place Update** - If instance is running and autoUpdate is enabled:
   - Runs `nixos-rebuild switch` inside the container
   - Only changed services restart
   - tmux sessions usually survive
   - No full container recreation

## Module Configuration

### Container Options

```nix
containers.<name> = {
  image = "alias";              # Image alias in Incus
  imagePackage = pkgs.package;  # Package with metadata.tar.xz + rootfs.tar.xz
  autoUpdate = true;            # Auto-update on host rebuild
  autoStart = true;             # Auto-start on boot
  profile = "profile-name";     # Incus profile to use
  network = "network-name";     # Network to connect to
};
```

### Network Options

```nix
networks.<name> = {
  type = "bridge";
  bridge = "br0";        # Use existing bridge
  # OR create new:
  ipv4 = "10.0.20.1/24";
  nat = true;
};
```

### Profile Options

```nix
profiles.<name> = {
  description = "...";
  config = {
    "limits.cpu" = "4";
    "limits.memory" = "8GB";
    "security.privileged" = "false";
    "security.nesting" = "true";
  };
  devices = {
    root = {
      path = "/";
      pool = "default";
      type = "disk";
      size = "100GB";
    };
  };
};
```

### Storage Options

```nix
storage = {
  driver = "zfs";       # or "dir", "btrfs", "lvm"
  pool = "default";
  source = "tank/incus"; # For ZFS: dataset path
};
```

## User Package Management

Users inside containers can manage their own packages:

```bash
# SSH into container
ssh user@container

# Use home-manager
cd ~/.config/home-manager
vim home.nix  # Add packages
home-manager switch

# Or use nix-env
nix-env -iA nixpkgs.htop

# No host involvement needed!
```

## Helper Commands

```bash
# Manually update all instances (containers + VMs)
incus-update-instances

# Update specific instance
incus-update-instance myinstance

# Ensure instances exist (useful after impermanence wipe)
incus-ensure-instances

# Standard Incus commands also work
incus list
incus exec mycontainer -- bash
incus stop mycontainer
incus start mycontainer
```

## Example: Adding a New Container

1. Create `containers/devbox/default.nix`
2. Add to `flake.nix` nixosConfigurations and packages
3. Add to `hosts/<host>/incus.nix` containers section
4. Run `sudo nixos-rebuild switch`

Done! Container is created and running.

## Container vs MicroVM Use Cases

**Use Incus containers for:**
- ✅ Development environments on trusted networks
- ✅ Long-lived stateful workloads
- ✅ User-managed environments (home-manager)
- ✅ When you want minimal update disruption

**Use microvm.nix for:**
- ✅ DMZ/untrusted network workloads
- ✅ When you need kernel isolation
- ✅ Stateless ephemeral services

## How Auto-Update Works

On `nixos-rebuild switch`:

1. **Host rebuilds** - New system configuration activates
2. **Activation script runs** - Checks if containers exist, creates if needed
3. **Background update starts** - For each container with `autoUpdate = true`:
   ```bash
   incus exec <container> -- nixos-rebuild switch
   ```
4. **Container updates in-place** - Only changed services restart
5. **User sessions persist** - tmux, SSH sessions usually unaffected

## Benefits Over microvm.nix (for dev workloads)

| Feature | microvm.nix | Incus Containers |
|---------|-------------|------------------|
| Writable /nix/store | ⚠️ Requires writableStoreOverlay | ✅ Native |
| Update disruption | ❌ Full VM restart | ✅ Only changed services |
| tmux survives updates | ❌ No | ✅ Usually yes |
| User package management | ⚠️ Complex | ✅ Simple |
| Declarative | ✅ Yes | ✅ Yes |
| Kernel isolation | ✅ Yes (KVM) | ❌ No (shared kernel) |
| Suitable for DMZ | ✅ Yes | ❌ No |

## Troubleshooting

### Container Doesn't Auto-Create

Check Incus service status:
```bash
systemctl status incus
journalctl -u incus
```

### Auto-Update Fails

Check update service:
```bash
journalctl -u incus-instance-updates
```

Manually update:
```bash
incus-update-instance myinstance
```

### Network Issues

Verify bridge exists:
```bash
ip link show br20
incus network show incusbr20
```

## Implementation Details

- Container images are built as packages: `pkgs.mmell.<name>-image`
- Images are imported automatically on first activation
- Instances persist across host reboots (impermanence-friendly)
- Updates run `nixos-rebuild switch` inside containers
- No flake refs needed (uses package references from overlay)
