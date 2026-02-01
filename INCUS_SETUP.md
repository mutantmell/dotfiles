# Incus Container Management Setup

## Overview

This repository now includes declarative Incus container management with automatic in-place updates. Containers are automatically updated when you run `nixos-rebuild switch` on the host, with minimal disruption (only changed services restart).

## Architecture

```
Host (muspelheim)
├── microVM guests (DMZ - VLAN 100)
│   ├── bragi (services)
│   └── ymir (services)
│
└── Incus containers (Trusted - VLAN 20)
    └── surtr (development environment)
        ├── System config: managed by host
        ├── User packages: managed via home-manager
        └── Persistent storage
```

## What Was Migrated

- **surtr**: Converted from microVM with `writableStoreOverlay` to Incus container
  - Previous: microVM on VLAN 100 with problematic writable store overlay
  - Now: Incus container with native writable /nix/store, cleaner architecture

## Files Added/Modified

### New Files
```
modules/incus/default.nix          # Incus management module
containers/surtr/configuration.nix  # surtr container system config
hosts/muspelheim/incus.nix          # Incus host configuration
INCUS_SETUP.md                      # This file
```

### Modified Files
```
flake.nix                           # Added container image outputs
hosts/muspelheim/configuration.nix  # Added incus.nix import
```

## Deployment Guide

### Step 1: Initial Host Setup

On muspelheim, rebuild the system to enable Incus:

```bash
# On muspelheim host
cd /etc/nixos
sudo nixos-rebuild switch

# This will:
# - Install and configure Incus
# - Set up storage pool (ZFS: persist/incus)
# - Configure network (uses existing br20 bridge)
# - Create profiles
# - Enable auto-update service
```

### Step 2: Build Container Image

Build the surtr container image:

```bash
# On your build machine or muspelheim
nix build .#surtr-image

# This creates two files:
# - result/metadata.tar.xz
# - result/rootfs.tar.xz
```

### Step 3: Import Image into Incus

```bash
# On muspelheim
incus image import \
  result/metadata.tar.xz \
  result/rootfs.tar.xz \
  --alias surtr:v1

# Verify image imported
incus image list
```

### Step 4: Create Container Instance

```bash
# Launch the container
incus launch surtr:v1 surtr --profile dev

# The container will:
# - Start automatically
# - Get an IP via DHCP on br20 (VLAN 20)
# - Be ready for SSH access
```

### Step 5: Initial Container Setup

```bash
# Get container's IP address
incus list surtr

# SSH into container (initial password: "changeme")
ssh root@<container-ip>

# Inside container:
# 1. Change root password
passwd

# 2. Create your user account
# Edit /etc/nixos and add your user, then:
nixos-rebuild switch

# 3. Set up home-manager for your user
# (User can manage their own packages from now on)
```

## Daily Workflow

### Host Administrator Updates

When you update the container's system configuration:

```bash
# 1. Edit container config
vim containers/surtr/configuration.nix
# Example: Add a system package, change SSH settings, etc.

# 2. Commit changes (optional but recommended)
git add containers/surtr/configuration.nix
git commit -m "Add postgresql to surtr system packages"

# 3. Rebuild host
sudo nixos-rebuild switch

# What happens:
# - Host rebuilds successfully
# - Background process starts
# - Connects to surtr container
# - Runs: nixos-rebuild switch inside container
# - Only changed services restart
# - tmux sessions usually survive!
```

### User Updates (Inside Container)

Users can manage their own packages:

```bash
# SSH into container
ssh user@surtr

# Update user packages via home-manager
cd ~/.config/home-manager
vim home.nix  # Add packages
home-manager switch

# Or use nix-env
nix-env -iA nixpkgs.ripgrep

# No host involvement needed!
# No container restart!
```

## Management Commands

### Container Lifecycle

```bash
# List containers
incus list

# Start/stop container
incus start surtr
incus stop surtr
incus restart surtr

# Execute command in container
incus exec surtr -- command

# Get a shell
incus exec surtr -- bash

# Copy files to/from container
incus file push localfile surtr/path/to/destination
incus file pull surtr/path/to/file ./localfile
```

### Manual Updates

```bash
# Update all managed containers
incus-update-containers

# Update specific container
incus-update-container surtr

# Check update service status
systemctl status incus-container-updates
```

### Image Management

```bash
# List images
incus image list

# Import new image version
nix build .#surtr-image
incus image import result/metadata.tar.xz result/rootfs.tar.xz --alias surtr:v2

# Update container to use new image (optional - auto-update handles this)
incus stop surtr
incus config set surtr volatile.base_image surtr:v2
incus start surtr

# Delete old images
incus image delete surtr:v1
```

### Snapshots

```bash
# Create snapshot
incus snapshot surtr backup-$(date +%Y%m%d)

# List snapshots
incus info surtr

# Restore snapshot
incus restore surtr backup-20260201

# Delete snapshot
incus delete surtr/backup-20260201
```

## Troubleshooting

### Container Won't Start

```bash
# Check container status
incus list

# View container logs
incus console surtr

# Check Incus service
systemctl status incus
journalctl -u incus -n 100
```

### Auto-Update Fails

```bash
# Check update service
journalctl -u incus-container-updates -n 100

# Manually update container
incus exec surtr -- nixos-rebuild switch --flake git+file:///etc/nixos#surtr-image
```

### Network Issues

```bash
# Verify bridge exists
ip link show br20

# Check container network config
incus network show incusbr20

# Inside container, check networking
incus exec surtr -- ip addr
incus exec surtr -- ip route
incus exec surtr -- ping 10.0.20.1
```

### Can't Build Container Image

```bash
# Ensure container config is valid
nix eval .#nixosConfigurations.surtr-image.config.system.name

# Build with verbose output
nix build .#surtr-image --show-trace
```

## Adding More Containers

### Step 1: Create Container Configuration

```bash
mkdir -p containers/newcontainer
```

Create `containers/newcontainer/configuration.nix`:

```nix
{ pkgs, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  networking.hostName = "newcontainer";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Your configuration here
  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  system.stateVersion = "24.05";
}
```

### Step 2: Add to Flake

Edit `flake.nix` and add:

```nix
# In nixosConfigurations:
newcontainer-image = self.lib.mk-nixos {
  inherit nixpkgs;
  system = "x86_64-linux";
  modules = [
    home-manager.nixosModules.home-manager
    ./containers/newcontainer/configuration.nix
  ];
};

# In packages (x86_64-linux section):
newcontainer-image = (mkContainerImage "newcontainer" self.nixosConfigurations.newcontainer-image).combined;
```

### Step 3: Add to Host Configuration

Edit `hosts/muspelheim/incus.nix`:

```nix
incus-manager.containers.newcontainer = {
  image = "newcontainer-image";
  autoUpdate = true;
  profile = "dev";
  network = "incusbr20";
  autoStart = true;
  flakeRef = "git+file:///etc/nixos#newcontainer-image";
};
```

### Step 4: Deploy

```bash
# Build and import image
nix build .#newcontainer-image
incus image import result/metadata.tar.xz result/rootfs.tar.xz --alias newcontainer:v1

# Launch container
incus launch newcontainer:v1 newcontainer --profile dev
```

## Migration from microVM

If you have existing microVMs you want to convert:

### Step 1: Export Data

```bash
# From inside microVM
ssh user@oldvm
tar czf /tmp/backup.tar.gz /home /etc /var/lib/important-data

# Copy to host
scp user@oldvm:/tmp/backup.tar.gz /tmp/
```

### Step 2: Create Container Config

Create container configuration based on microVM's `configuration.nix`, adapting:
- Remove `microvm.*` options
- Add `lxc-container.nix` import
- Update networking to use DHCP or static via systemd-networkd
- Review and update any paths that referenced `/persist` or `/static`

### Step 3: Deploy Container

Follow "Adding More Containers" steps above.

### Step 4: Restore Data

```bash
# Extract backup
tar xzf /tmp/backup.tar.gz -C /tmp/extracted/

# Copy into container
incus file push -r /tmp/extracted/home newcontainer/
incus file push -r /tmp/extracted/etc newcontainer/
# etc.
```

### Step 5: Decommission microVM

Once verified, remove microVM from host configuration:

```bash
# Edit hosts/muspelheim/microvm.nix
# Remove old VM definition

# Rebuild
sudo nixos-rebuild switch
```

## Configuration Reference

### Incus Module Options

See `modules/incus/default.nix` for full options. Key options:

```nix
incus-manager = {
  enable = true;
  flakeUrl = "github:user/repo";  # Where to find configs

  storage = {
    driver = "zfs";  # or "dir", "btrfs", "lvm"
    pool = "default";
    source = "tank/incus";  # ZFS dataset
  };

  networks.mynet = {
    type = "bridge";
    bridge = "br0";  # Existing bridge
    # or create new:
    # ipv4 = "10.0.50.1/24";
    # nat = true;
  };

  profiles.myprofile = {
    config = {
      "limits.cpu" = "2";
      "limits.memory" = "2GB";
    };
    devices = {
      root = {
        path = "/";
        pool = "default";
        type = "disk";
        size = "20GB";
      };
    };
  };

  containers.mycontainer = {
    image = "mycontainer-image";
    autoUpdate = true;
    profile = "myprofile";
    network = "mynet";
    flakeRef = "github:user/repo#mycontainer-image";
  };
};
```

## Benefits Over microvm.nix for Development VMs

| Feature | microvm.nix | Incus Containers |
|---------|-------------|------------------|
| Writable /nix/store | ⚠️ Problematic (writableStoreOverlay) | ✅ Native |
| User package management | ⚠️ Complex | ✅ Simple (home-manager, nix-env) |
| Update disruption | ❌ Full VM restart | ✅ Only changed services |
| tmux survives updates | ❌ No | ✅ Usually yes |
| Image/instance separation | ❌ No | ✅ Yes |
| State persistence | ⚠️ Manual volumes | ✅ Built-in |
| Declarative | ✅ Yes | ✅ Yes |
| Kernel isolation | ✅ Yes (KVM) | ❌ No (shared kernel) |

**Use microvm.nix for**: DMZ/untrusted workloads requiring kernel isolation
**Use Incus containers for**: Development environments on trusted networks

## Further Reading

- [Incus Documentation](https://linuxcontainers.org/incus/docs/latest/)
- [NixOS Containers Wiki](https://wiki.nixos.org/wiki/NixOS_Containers)
- [LXC Container Documentation](https://linuxcontainers.org/lxc/documentation/)

## Support

For issues with:
- **Incus module**: Check `modules/incus/default.nix`
- **Container configs**: Check `containers/*/configuration.nix`
- **Host integration**: Check `hosts/*/incus.nix`
- **Build errors**: Run with `--show-trace` and check flake.nix
