# nixos-anywhere Integration Plan

## Overview

This plan restructures the dotfiles repository to properly integrate nixos-anywhere deployment capabilities into the main flake, eliminating the isolated `anywhere/` directory and establishing disko as the single source of truth for disk configurations.

**SCOPE:** This migration focuses exclusively on **thebeyond** (the router). VM hosts (calvard, erebonia) are documented for future reference but are **OUT OF SCOPE** for this migration.

## Goals

1. Integrate nixos-anywhere deployment into the main flake
2. Use shared disko profiles for disk configuration
3. Eliminate duplication between hardware-configuration.nix and disko configs
4. Add deployment tooling and documentation
5. Enable VM testing before real hardware deployment
6. **Encrypt /persist with LUKS using keyfile-based automatic unlock**

## In-Scope vs Out-of-Scope

### ✅ In Scope (This Migration)

- Migrate **thebeyond** to new nixos-anywhere/disko structure
- Add disko input to main flake
- Create shared disko profile for routers (used by thebeyond)
- Add LUKS encryption to thebeyond
- Create deployment scripts and documentation
- Delete isolated `anywhere/` directory

### ⏸️ Out of Scope (Future Work)

- Migrating **calvard** to new structure (vm-host, not scheduled for teardown yet)
- Migrating **erebonia** to new structure (vm-host, not scheduled for teardown yet)
- VM host configurations will be **documented** for when they are ready to be rebuilt from scratch

## Current State Analysis

### Issues Identified (Thebeyond-Specific)

1. **Separate Flakes**: `anywhere/flake.nix` is isolated from `flake.nix`, causing duplication
2. **Untested Configuration**: No validation that nixos-anywhere setup for thebeyond actually works
3. **Dual Disk Definitions**: Thebeyond's `hardware-configuration.nix` and disko define filesystems, risking conflicts
4. **Missing Deployment Tooling**: No helper scripts or clear deployment process for thebeyond
5. **No Encryption**: Thebeyond's /persist is currently unencrypted

### Current Structure

```
/root/dotfiles/
├── flake.nix                          # Main flake (no disko integration)
├── anywhere/
│   ├── flake.nix                      # Separate flake with disko
│   ├── common.nix
│   └── profiles/
│       ├── router.nix                 # Router disko profile
│       └── vm-host.nix                # VM host disko profile
└── hosts/
    ├── thebeyond/
    │   ├── configuration.nix
    │   ├── hardware-configuration.nix # Contains filesystem definitions
    │   ├── impermanence.nix
    │   ├── microvm.nix
    │   └── sops.nix
    ├── calvard/                      # VM host
    └── erebonia/                    # VM host
```

## Target State

### New Structure (After Migration)

```
/root/dotfiles/
├── flake.nix                          # Main flake WITH disko integration
├── flake.lock                         # Updated with disko input
│
├── profiles/
│   └── disko/
│       ├── router.nix                 # Shared router disk layout (✅ USED BY THEBEYOND)
│       └── vm-host.nix                # Shared VM host disk layout (⏸️ FOR FUTURE USE)
│
├── hosts/
│   ├── thebeyond/                     # ✅ MIGRATED IN THIS PLAN
│   │   ├── configuration.nix          # Updated: imports disko profile, LUKS config
│   │   ├── hardware-configuration.nix # Regenerated with --no-filesystems
│   │   ├── impermanence.nix
│   │   ├── microvm.nix
│   │   └── sops.nix
│   ├── calvard/                      # ⏸️ NOT MIGRATED (future work)
│   │   ├── configuration.nix          # Unchanged
│   │   └── hardware-configuration.nix # Unchanged
│   └── erebonia/                    # ⏸️ NOT MIGRATED (future work)
│       ├── configuration.nix          # Unchanged
│       └── hardware-configuration.nix # Unchanged
│
├── scripts/
│   ├── deploy-nixos-anywhere.sh      # Deployment wrapper
│   └── test-disko-vm.sh               # VM testing script
│
├── docs/
│   ├── deployment.md                  # Deployment guide
│   └── nixos-anywhere-integration-plan.md  # This document
│
└── anywhere/                          # ✅ DELETED
```

## Encryption Strategy

### Approach: LUKS with Keyfile on /boot

**Decision:** Encrypt /persist using LUKS with automatic unlock via keyfile stored on /boot.

**Security Model:**

- **Protects against:** Disk removed from router and connected elsewhere, remote data exfiltration of /persist only
- **Does NOT protect against:** Physical theft of entire router (both encrypted data and key are present)
- **Philosophy:** Baseline encryption is better than no encryption; can upgrade to stronger methods later

**Hardware Constraints:**

- Router hardware does not support TPM 2.0 (too old for TPM-based automatic unlock)
- Tang/Clevis network-bound encryption deferred (too many unknowns, added complexity)

**Future Upgrade Paths:**

1. **USB key storage** - Move keyfile to USB stick, require USB insertion for boot
2. **Tang/Clevis** - Set up Tang server on calvard/erebonia when ready
3. **Multiple key slots** - Add Tang as backup while keeping keyfile for redundancy
4. **Key rotation** - LUKS supports multiple key slots, can rotate keys without re-encrypting

**Benefits of This Approach:**

- ✅ Simple, well-understood, minimal moving parts
- ✅ Works seamlessly with nixos-anywhere
- ✅ Autonomous reboots from day 1
- ✅ Easier to encrypt from the start than retrofit later
- ✅ Clear migration path to stronger encryption methods
- ✅ LUKS key slots allow future changes without data re-encryption

## Implementation Steps

> **⚠️ SCOPE REMINDER:** These steps migrate **thebeyond only**. VM hosts (calvard, erebonia) are NOT modified in this plan. See "Future Work" section for vm-host migration when needed.

### Phase 1: Integrate disko into Main Flake

**1.1: Add disko input to main flake.nix**

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
  home-manager.url = "github:nix-community/home-manager";
  microvm.url = "github:astro/microvm.nix";
  microvm-stable.url = "github:astro/microvm.nix";
  sops-nix.url = "github:Mic92/sops-nix";
  impermanence.url = "github:nix-community/impermanence";
  disko.url = "github:nix-community/disko";  # ADD THIS
  disko.inputs.nixpkgs.follows = "nixpkgs";
};
```

**1.2: Update flake.lock**

```bash
nix flake lock --update-input disko
```

**1.3: Include disko module in system configurations**

Update the `outputs` section to include `disko.nixosModules.disko` for each host that will use nixos-anywhere deployment.

### Phase 2: Migrate Disko Profiles

**2.1: Create profiles/disko/ directory**

```bash
mkdir -p profiles/disko
```

**2.2: Move and update router.nix**

Copy `anywhere/profiles/router.nix` to `profiles/disko/router.nix` and update to include LUKS encryption:

```nix
{ lib, ... }:
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = lib.mkDefault "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02"; # GRUB boot partition
            };
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptroot";
                # Keyfile for nixos-anywhere deployment
                keyFile = "/tmp/secret.key";
                settings = {
                  allowDiscards = true;
                };
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/persist";
                };
              };
            };
          };
        };
      };
    };
    nodev = {
      "/" = {
        fsType = "tmpfs";
        mountOptions = [
          "defaults"
          "size=${lib.mkDefault "2G"}"
          "mode=755"
        ];
      };
    };
  };
}
```

**Key changes:**

- Added LUKS layer wrapping the ext4 filesystem
- `keyFile = "/tmp/secret.key"` - nixos-anywhere will pass this during deployment
- `allowDiscards = true` - enables TRIM support for SSDs
- Device name `cryptroot` - will be accessible as `/dev/mapper/cryptroot` when unlocked

**2.3: Move vm-host.nix (for future use)**

Copy `anywhere/profiles/vm-host.nix` to `profiles/disko/vm-host.nix` for future reference.

**Note:** This profile is NOT used in this migration. It's preserved for when calvard/erebonia are ready to be rebuilt from scratch.

**2.4: Delete anywhere/ directory**

```bash
rm -rf anywhere/
```

### Phase 3: Update Host Configurations

**3.1: Update thebeyond configuration.nix**

Ensure it imports the disko profile and configures LUKS unlock:

```nix
{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../profiles/disko/router.nix  # ADD THIS
    ./impermanence.nix
    ./microvm.nix
    ./sops.nix
  ];

  # LUKS automatic unlock configuration
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/<UUID>";  # Will be filled in after deployment
    keyFile = "/boot/secrets/disk.key";
    allowDiscards = true;
  };

  # Ensure /boot/secrets directory exists
  system.activationScripts.createBootSecrets = ''
    mkdir -p /boot/secrets
    chmod 700 /boot/secrets
  '';

  # ... rest of configuration
}
```

**Note:** The UUID will be determined after first deployment and must be filled in manually.

**3.2: Regenerate thebeyond hardware-configuration.nix**

After deploying with nixos-anywhere, regenerate hardware config WITHOUT filesystem definitions:

```bash
# After nixos-anywhere deployment completes:
ssh root@thebeyond
nixos-generate-config --no-filesystems --show-hardware-config > /tmp/hardware-config.nix
exit

# Copy back to repo
scp root@thebeyond:/tmp/hardware-config.nix hosts/thebeyond/hardware-configuration.nix
```

**Important**: The new hardware-configuration.nix should:

- NOT contain any `fileSystems.*` definitions (disko handles this)
- Keep `boot.initrd.availableKernelModules`
- Keep `boot.initrd.kernelModules`
- Keep `boot.kernelModules`
- Keep `nixpkgs.hostPlatform`
- Keep any `boot.loader.*` settings if auto-detected

**3.3: Update flake.nix host definition for thebeyond**

Only thebeyond is being migrated in this plan. Update its configuration:

```nix
nixosConfigurations = {
  thebeyond = mk-nixos {
    hostname = "thebeyond";
    system = "x86_64-linux";
    nixpkgs = inputs.nixpkgs;
    modules = [
      inputs.disko.nixosModules.disko  # ADD THIS
      ./hosts/thebeyond/configuration.nix
      ./modules/common
      ./modules/router6
      inputs.microvm-stable.nixosModules.host
      inputs.sops-nix.nixosModules.sops
      inputs.impermanence.nixosModules.impermanence
    ];
  };

  # calvard - NOT MODIFIED (out of scope)
  calvard = mk-nixos {
    hostname = "calvard";
    system = "x86_64-linux";
    nixpkgs = inputs.nixpkgs;
    modules = [
      # NO disko module added - not migrating yet
      ./hosts/calvard/configuration.nix
      ./modules/common
      ./modules/router6
      inputs.microvm.nixosModules.host
      inputs.sops-nix.nixosModules.sops
    ];
  };

  # erebonia - NOT MODIFIED (out of scope)
  # ... keep existing configuration unchanged
};
```

### Phase 4: Add Deployment Tooling

**4.1: Create deployment script**

Create `scripts/deploy-nixos-anywhere.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# nixos-anywhere deployment wrapper with LUKS encryption support
# Usage: ./scripts/deploy-nixos-anywhere.sh <hostname> <target-ip> [extra-args]

HOSTNAME="${1:-}"
TARGET="${2:-}"

if [[ -z "$HOSTNAME" || -z "$TARGET" ]]; then
    echo "Usage: $0 <hostname> <target-ip> [extra-args]"
    echo ""
    echo "Examples:"
    echo "  $0 thebeyond root@192.168.1.100"
    echo "  $0 calvard user@example.com --build-on-remote"
    echo ""
    echo "Available hosts:"
    nix flake show 2>/dev/null | grep "nixosConfigurations" -A 10 | grep "├" | sed 's/.*├─ /  - /'
    exit 1
fi

shift 2
EXTRA_ARGS="$@"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Generate encryption keyfile
KEYFILE_DIR=$(mktemp -d)
KEYFILE="$KEYFILE_DIR/disk.key"
trap "rm -rf $KEYFILE_DIR" EXIT

echo "Generating LUKS encryption keyfile..."
dd if=/dev/urandom of="$KEYFILE" bs=4096 count=1 2>/dev/null
chmod 600 "$KEYFILE"

echo ""
echo "======================================"
echo "nixos-anywhere Deployment (Encrypted)"
echo "======================================"
echo "Host:       $HOSTNAME"
echo "Target:     $TARGET"
echo "Flake:      $REPO_ROOT#$HOSTNAME"
echo "Encryption: LUKS with keyfile"
echo "Extra args: ${EXTRA_ARGS:-none}"
echo "======================================"
echo ""

# Confirm deployment
read -p "Deploy $HOSTNAME to $TARGET? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    rm -rf "$KEYFILE_DIR"
    exit 1
fi

# Save keyfile to repo for later use (gitignored)
mkdir -p "$REPO_ROOT/.keys"
cp "$KEYFILE" "$REPO_ROOT/.keys/$HOSTNAME-disk.key"
chmod 600 "$REPO_ROOT/.keys/$HOSTNAME-disk.key"

# Run nixos-anywhere with encryption
nix run github:nix-community/nixos-anywhere -- \
    --flake "$REPO_ROOT#$HOSTNAME" \
    --target-host "$TARGET" \
    --disk-encryption-keys /tmp/secret.key "$KEYFILE" \
    $EXTRA_ARGS

echo ""
echo "======================================"
echo "Deployment complete!"
echo "======================================"
echo ""
echo "IMPORTANT: Post-deployment steps required!"
echo ""
echo "1. Copy the encryption keyfile to /boot:"
echo "   scp $REPO_ROOT/.keys/$HOSTNAME-disk.key root@$TARGET:/boot/secrets/disk.key"
echo "   ssh root@$TARGET 'chmod 600 /boot/secrets/disk.key'"
echo ""
echo "2. Find the LUKS UUID and update configuration.nix:"
echo "   ssh root@$TARGET 'blkid | grep crypto_LUKS'"
echo "   # Update hosts/$HOSTNAME/configuration.nix with the UUID"
echo ""
echo "3. Regenerate hardware-config without filesystems:"
echo "   ssh root@$TARGET 'nixos-generate-config --no-filesystems --show-hardware-config > /tmp/hardware-config.nix'"
echo "   scp root@$TARGET:/tmp/hardware-config.nix $REPO_ROOT/hosts/$HOSTNAME/hardware-configuration.nix"
echo ""
echo "4. Rebuild the system with updated configuration:"
echo "   ssh root@$TARGET 'nixos-rebuild switch'"
echo ""
echo "5. Test autonomous reboot:"
echo "   ssh root@$TARGET 'reboot'"
echo "   # Wait for boot and verify automatic unlock worked"
echo ""
echo "Encryption keyfile saved to: $REPO_ROOT/.keys/$HOSTNAME-disk.key"
echo "BACKUP THIS FILE SECURELY - you cannot decrypt /persist without it!"
echo ""
```

Make it executable:

```bash
chmod +x scripts/deploy-nixos-anywhere.sh
```

**4.2: Create VM testing script**

Create `scripts/test-disko-vm.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Test disko configuration in a VM before deploying to real hardware
# Usage: ./scripts/test-disko-vm.sh <hostname>

HOSTNAME="${1:-}"

if [[ -z "$HOSTNAME" ]]; then
    echo "Usage: $0 <hostname>"
    echo ""
    echo "This script tests the disko disk configuration in a VM"
    echo "before deploying to real hardware."
    echo ""
    echo "Available hosts:"
    nix flake show 2>/dev/null | grep "nixosConfigurations" -A 10 | grep "├" | sed 's/.*├─ /  - /'
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "======================================"
echo "Testing $HOSTNAME disko config in VM"
echo "======================================"

# Use disko's VM testing
nix run github:nix-community/disko -- \
    --mode disko \
    --flake "$REPO_ROOT#$HOSTNAME" \
    --dry-run

echo ""
echo "Dry run successful! To test in a VM:"
echo ""
echo "  nix run github:nix-community/disko -- \\"
echo "    --mode test \\"
echo "    --flake $REPO_ROOT#$HOSTNAME"
```

Make it executable:

```bash
chmod +x scripts/test-disko-vm.sh
```

**4.3: Create deployment documentation**

Create `docs/deployment.md` with:

- Prerequisites (SSH access, target machine requirements)
- Step-by-step deployment process
- Troubleshooting guide
- VM testing instructions
- Post-deployment steps

### Phase 5: Testing and Validation

**5.1: Validate flake structure**

```bash
nix flake check
nix flake show
```

**5.2: Test disko configuration**

```bash
# Dry-run to validate disko syntax
./scripts/test-disko-vm.sh thebeyond
```

**5.3: Test deployment to VM (optional)**

Set up a test VM and deploy to it before touching real hardware:

```bash
# Create a VM for testing
# Deploy to VM
./scripts/deploy-nixos-anywhere.sh thebeyond root@<vm-ip> --vm-test
```

**5.4: Deploy to real hardware**

When ready:

```bash
./scripts/deploy-nixos-anywhere.sh thebeyond root@<thebeyond-ip>
```

## Key Technical Details

### Direct Hard Drive Installation

nixos-anywhere uses **kexec** to boot the target machine into a temporary NixOS installer in RAM, then partitions and installs to the hard drive. This means:

- **No boot media required** - works over SSH
- **Requirements**:
  - Target machine running any Linux OS with SSH access
  - Minimum 1.5 GB RAM (for kexec environment)
  - Network connectivity (WiFi not supported)
  - Root or passwordless sudo access

### Disko vs hardware-configuration.nix

**Division of Responsibilities:**

| Component                  | Handles                                                  |
| -------------------------- | -------------------------------------------------------- |
| Disko                      | Disk partitioning, formatting, mount points, filesystems |
| hardware-configuration.nix | CPU/GPU detection, kernel modules, boot loader settings  |

**Why both?**

- Disko's `nixosModules.disko` automatically generates `fileSystems.*` configuration
- hardware-configuration.nix (with `--no-filesystems`) captures hardware-specific settings that can't be in disko
- Together they provide the complete hardware + disk configuration

### Parameterization

Disko profiles use `lib.mkDefault` for parameterization:

```nix
# In profiles/disko/router.nix
device = lib.mkDefault "/dev/sda";

# Can be overridden in configuration.nix
disko.devices.disk.main.device = "/dev/nvme0n1";
```

This allows shared profiles to work with different hardware.

## Important: Keyfile Storage and Git

**CRITICAL:** Encryption keyfiles must NEVER be committed to git!

Add to `.gitignore`:

```
# LUKS encryption keyfiles
.keys/
*.key
```

The deployment script saves keyfiles to `.keys/<hostname>-disk.key` for convenience, but this directory must be gitignored and backed up separately to secure storage (password manager, encrypted backup drive, etc.).

## Migration Checklist (Thebeyond Only)

### Phase 1: Flake Integration

- [ ] Add disko input to main flake.nix
- [ ] Update flake.lock
- [ ] Update flake.nix thebeyond configuration to include disko module

### Phase 2: Disko Profiles

- [ ] Create profiles/disko/ directory
- [ ] Move router.nix to profiles/disko/ and add LUKS encryption layer
- [ ] Move vm-host.nix to profiles/disko/ (for future use, not actively used)
- [ ] Delete anywhere/ directory

### Phase 3: Thebeyond Host Configuration

- [ ] Update thebeyond configuration.nix to import disko profile
- [ ] Add LUKS unlock configuration to thebeyond configuration.nix
- [ ] Add activation script to create /boot/secrets directory

### Phase 4: Deployment Tooling

- [ ] Create .keys/ directory for storing keyfiles
- [ ] Add .keys/ to .gitignore
- [ ] Create scripts/deploy-nixos-anywhere.sh with encryption support
- [ ] Create scripts/test-disko-vm.sh
- [ ] Create docs/deployment.md with encryption instructions
- [ ] Make scripts executable

### Phase 5: Testing

- [ ] Test flake: `nix flake check`
- [ ] Test disko validation: `./scripts/test-disko-vm.sh thebeyond`
- [ ] Deploy to test environment (optional)

### Phase 6: Production Deployment (Thebeyond)

- [ ] Deploy to production hardware: `./scripts/deploy-nixos-anywhere.sh thebeyond root@<ip>`
- [ ] Copy encryption keyfile to /boot/secrets/disk.key
- [ ] Get LUKS UUID and update configuration.nix
- [ ] Regenerate hardware-configuration.nix with --no-filesystems
- [ ] Commit updated hardware-configuration.nix
- [ ] Rebuild system with updated configuration
- [ ] Test autonomous reboot
- [ ] Backup encryption keyfile to secure location
- [ ] Update README to mention nixos-anywhere deployment

## Post-Deployment

After successful deployment:

1. **Copy encryption keyfile to router:**

   ```bash
   scp .keys/thebeyond-disk.key root@thebeyond:/boot/secrets/disk.key
   ssh root@thebeyond 'chmod 600 /boot/secrets/disk.key'
   ```

2. **Update configuration.nix with LUKS UUID:**

   ```bash
   ssh root@thebeyond 'blkid | grep crypto_LUKS'
   # Copy UUID and update hosts/thebeyond/configuration.nix
   ```

3. **Regenerate hardware-config** and commit it:

   ```bash
   ssh root@thebeyond 'nixos-generate-config --no-filesystems --show-hardware-config > /tmp/hw.nix'
   scp root@thebeyond:/tmp/hw.nix hosts/thebeyond/hardware-configuration.nix
   ```

4. **Rebuild with updated configuration:**

   ```bash
   # Commit changes first
   git add hosts/thebeyond/configuration.nix hosts/thebeyond/hardware-configuration.nix
   git commit -m "Update thebeyond post-deployment config"

   # Rebuild on router
   ssh root@thebeyond 'nixos-rebuild switch --flake /etc/nixos#thebeyond'
   ```

5. **Test autonomous reboot:**

   ```bash
   ssh root@thebeyond 'reboot'
   # Wait ~30 seconds, then verify it comes back up
   ssh root@thebeyond 'uptime'
   ```

6. **Verify encryption and filesystems:**

   ```bash
   ssh root@thebeyond 'lsblk'
   ssh root@thebeyond 'df -h'
   ssh root@thebeyond 'mount | grep mapper'
   ```

7. **Backup encryption keyfile securely:**
   - Store `.keys/thebeyond-disk.key` in password manager
   - Store backup on encrypted USB drive
   - **CRITICAL: Without this keyfile, /persist cannot be decrypted!**

8. **Test impermanence** (reboot and verify /persist survives)

9. **Set up secrets** (SOPS keys if not already present)

10. **Deploy actual router configuration** using standard rebuild

## Benefits of This Approach

1. **Single source of truth**: One flake, disko defines disks, hardware-config defines hardware
2. **Repeatable deployments**: Can redeploy thebeyond from scratch anytime
3. **Testable**: Can validate disk configs in VM before touching hardware
4. **Maintainable**: Shared profiles reduce duplication
5. **Documented**: Clear deployment process for future reference
6. **Encrypted from day 1**: /persist protected with LUKS, autonomous reboots work
7. **Upgradeable**: Can migrate to Tang/Clevis or USB keyfile later without re-encrypting

## Risk Mitigation

- Test in VM before deploying to real hardware
- Have physical access to thebeyond during first deployment
- Backup any critical data from /persist before deploying
- Keep network configuration simple initially (can add complexity after successful boot)

## Questions/Unknowns

None remaining - all original questions answered:

1. ✅ Separate flake issue → Integrate into main flake
2. ✅ Untested configuration → Add VM testing and validation
3. ✅ Dual disk definitions → Use disko + hardware-config with --no-filesystems
4. ✅ Direct hard drive install → nixos-anywhere supports this via kexec
5. ✅ Encryption + autonomous reboot → LUKS with keyfile on /boot

## Future Encryption Upgrade Paths

The keyfile-on-/boot approach is pragmatic for initial deployment, but can be upgraded later:

### Option 1: USB Key Storage

Move keyfile to USB drive that must be inserted during boot:

```nix
boot.initrd.luks.devices."cryptroot" = {
  device = "/dev/disk/by-uuid/...";
  keyFile = "/dev/disk/by-id/usb-...-part1";  # USB device path
  keyFileSize = 4096;
  allowDiscards = true;
};
```

**Security improvement:** Physical access requires both router AND USB key

### Option 2: Tang/Clevis Network-Bound Encryption

Set up Tang server on calvard or erebonia:

```bash
# On calvard/erebonia (Tang server)
# Add to configuration.nix:
services.tang.enable = true;

# On thebeyond (client)
# Bind existing LUKS volume to Tang:
clevis luks bind -d /dev/sda3 tang '{"url":"http://calvard:8006"}'

# Update configuration.nix:
boot.initrd.clevis.useTang = true;
boot.initrd.network.enable = true;
```

**Security improvement:** Requires both physical disk AND network access to Tang server

### Option 3: Dual Key Slots (Keyfile + Tang)

LUKS supports multiple key slots - can have both for redundancy:

```bash
# Existing keyfile in slot 0
# Add Tang in slot 1
clevis luks bind -d /dev/sda3 tang '{"url":"http://calvard:8006"}' -s 1

# System tries Tang first, falls back to keyfile if network unavailable
```

**Security improvement:** Tang for normal boots, keyfile as backup

### Migration Notes

- All upgrades can be done without re-encrypting /persist
- LUKS supports 8 key slots - can test new methods before removing old
- Always keep a backup unlock method until new method is proven
- Can rotate/revoke key slots: `cryptsetup luksKillSlot /dev/sda3 0`

## Future Work: VM Host Migration (Out of Scope)

When calvard and/or erebonia are ready to be torn down and rebuilt from scratch, follow these steps:

### Prerequisites

- The `profiles/disko/vm-host.nix` profile is already in place (moved in Phase 2)
- The deployment scripts already support any host in the flake
- The main flake already has disko as an input

### Migration Steps for Each VM Host

**1. Update host configuration.nix**

```nix
# hosts/calvard/configuration.nix (or erebonia)
{
  imports = [
    ./hardware-configuration.nix
    ../../profiles/disko/vm-host.nix  # ADD THIS
    # ... other imports
  ];

  # Add LUKS configuration if desired (optional for VM hosts)
  # boot.initrd.luks.devices."cryptroot" = { ... };
}
```

**2. Update flake.nix**

```nix
calvard = mk-nixos {
  hostname = "calvard";
  system = "x86_64-linux";
  nixpkgs = inputs.nixpkgs;
  modules = [
    inputs.disko.nixosModules.disko  # ADD THIS
    ./hosts/calvard/configuration.nix
    # ... other modules
  ];
};
```

**3. Deploy**

```bash
./scripts/deploy-nixos-anywhere.sh calvard root@<ip>
# Follow post-deployment steps as documented
```

**4. Verify vm-host.nix profile**

Review `profiles/disko/vm-host.nix` and adjust as needed for current requirements:

- Check if ZFS encryption settings are still desired
- Verify disk device paths (may differ from original)
- Update tmpfs sizes if needed

**Notes:**

- VM hosts may or may not need LUKS encryption (review security requirements)
- ZFS configuration in vm-host.nix may need updates based on current best practices
- Test in a VM first using `./scripts/test-disko-vm.sh calvard`

## References

- [nixos-anywhere Documentation](https://nix-community.github.io/nixos-anywhere/)
- [disko Documentation](https://github.com/nix-community/disko)
- [nixos-anywhere Examples](https://github.com/nix-community/nixos-anywhere-examples)
