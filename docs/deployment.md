# NixOS Deployment with nixos-anywhere

This guide covers deploying NixOS systems from scratch using nixos-anywhere with encrypted disks over the network.

## Prerequisites

### On Your Local Machine

- Nix with flakes enabled
- SSH access to target machine
- Network connectivity to target

### On Target Machine

- Any Linux OS with SSH access (will be replaced)
- Root access or passwordless sudo
- Minimum 1.5 GB RAM (for kexec environment)
- Network connectivity (WiFi not supported)
- **WARNING:** All data on target disk will be destroyed!

## Deployment Process

### 1. Deploy to Target Machine

```bash
./scripts/deploy-nixos-anywhere.sh thebeyond root@192.168.1.100
```

The script will:

- Generate a random LUKS encryption keyfile
- Boot target into kexec installer (no physical media needed)
- Partition and encrypt disk using disko
- Install NixOS
- Save keyfile to `.keys/thebeyond-disk.key`

### 2. Post-Deployment Configuration

After deployment completes, follow these steps:

#### a. Copy Encryption Keyfile

```bash
scp .keys/thebeyond-disk.key root@192.168.1.100:/boot/secrets/disk.key
ssh root@192.168.1.100 'chmod 600 /boot/secrets/disk.key'
```

#### b. Get LUKS UUID

```bash
ssh root@192.168.1.100 'blkid | grep crypto_LUKS'
```

Output will look like:

```
/dev/sda3: UUID="a1b2c3d4-..." TYPE="crypto_LUKS" PARTLABEL="persist"
```

Copy the UUID and update `hosts/thebeyond/default.nix`:

```nix
boot.initrd.luks.devices."cryptroot" = {
  device = "/dev/disk/by-uuid/a1b2c3d4-...";  # Replace with your UUID
  keyFile = "/boot/secrets/disk.key";
  allowDiscards = true;
};
```

#### c. Regenerate Hardware Configuration

```bash
ssh root@192.168.1.100 'nixos-generate-config --no-filesystems --show-hardware-config > /tmp/hw.nix'
scp root@192.168.1.100:/tmp/hw.nix hosts/thebeyond/hardware-configuration.nix
```

The `--no-filesystems` flag is important - disko already handles filesystem configuration.

#### d. Commit and Rebuild

```bash
git add hosts/thebeyond/default.nix hosts/thebeyond/hardware-configuration.nix
git commit -m "Update thebeyond post-deployment config"

# Rebuild on the router
ssh root@192.168.1.100 'nixos-rebuild switch --flake /etc/nixos#thebeyond'
```

#### e. Test Autonomous Reboot

```bash
ssh root@192.168.1.100 'reboot'
# Wait ~30 seconds
ssh root@192.168.1.100 'uptime'
```

If it boots successfully without password prompts, encryption is working!

#### f. Backup Encryption Keyfile

**CRITICAL:** Without this keyfile, you cannot decrypt `/persist`!

```bash
# Store in password manager
cat .keys/thebeyond-disk.key  # Copy to password manager

# Store on encrypted backup drive
cp .keys/thebeyond-disk.key /path/to/secure/backup/
```

### 3. Verify Deployment

```bash
# Check encryption status
ssh root@192.168.1.100 'lsblk'
# Should show /dev/mapper/cryptroot

# Check filesystems
ssh root@192.168.1.100 'df -h'
# Should show tmpfs on /, ext4 on /persist

# Check mount options
ssh root@192.168.1.100 'mount | grep mapper'
# Should show /dev/mapper/cryptroot on /persist
```

---

## Testing Before Production Deployment

### Configuration Validation

Run the check wrapper before production deployment:

```bash
./scripts/run-checks.sh
```

For a focused iteration, run the relevant check directly:

```bash
nix build .#checks.x86_64-linux.<name> --print-build-logs
```

Avoid `nix flake check` for this repository. The flake has many NixOS
evaluations and broad flake checking can OOM; `run-checks.sh` runs checks as
separate `nix build` processes to keep memory bounded.

The check set includes:

- Disko profile validation (router and vm-host)
- Router6 module tests
- Nftables DSL tests

### VM Testing (Optional)

Test full deployment in a VM before touching real hardware:

```bash
# Create test VM (adjust as needed)
# Deploy to VM
./scripts/deploy-nixos-anywhere.sh thebeyond root@<vm-ip> --vm-test
```

## Encryption Details

### Security Model

**Protects against:**

- Disk removed from router and connected elsewhere
- Remote data exfiltration of `/persist` only

**Does NOT protect against:**

- Physical theft of entire router (keyfile is on `/boot`)
- Targeted attacks on `/boot` partition

### Future Upgrades

The keyfile-on-`/boot` approach can be upgraded later without re-encrypting:

#### Option 1: USB Key Storage

Move keyfile to USB drive that must be inserted during boot.

#### Option 2: Tang/Clevis Network-Bound Encryption

Set up Tang server for network-bound encryption. See plan document for details.

#### Option 3: Dual Key Slots

LUKS supports 8 key slots - can have multiple unlock methods.

## Troubleshooting

### System Won't Boot After Deployment

1. **Check if keyfile exists:**

   ```bash
   # Boot from rescue media
   mount /dev/sda2 /mnt  # ESP partition
   ls -la /mnt/secrets/disk.key
   ```

2. **Manually unlock to debug:**

   ```bash
   cryptsetup open /dev/sda3 cryptroot
   # Enter passphrase if you set one during testing
   ```

3. **Check LUKS UUID matches:**
   ```bash
   blkid /dev/sda3
   # Compare with default.nix
   ```

### Can't SSH After Deployment

1. **Check if system booted:**
   - Physical access: check console
   - Network: ping the IP

2. **Try serial console:**

   ```bash
   # If you have physical access
   ```

3. **Boot from rescue media and check logs:**
   ```bash
   mount /dev/mapper/cryptroot /mnt
   mount /dev/sda2 /mnt/boot
   nixos-enter
   journalctl -b -1  # Previous boot
   ```

### Keyfile Lost

If you lost the keyfile but still have access to booted system:

```bash
# Generate new keyfile
dd if=/dev/urandom of=/boot/secrets/disk.key.new bs=4096 count=1

# Add to LUKS (requires current unlock method)
cryptsetup luksAddKey /dev/sda3 /boot/secrets/disk.key.new

# Backup new keyfile immediately!
# Then remove old key slot if desired
cryptsetup luksRemoveKey /dev/sda3
```

## Advanced Usage

### Custom Disk Device

Override default `/dev/sda`:

```nix
# In default.nix
disko.devices.disk.main.device = "/dev/nvme0n1";
```

### Deploy Without Encryption

To deploy a host without encryption, remove LUKS layer from disko profile and skip encryption keyfile steps.

### Build on Remote Host

For slow local machines:

```bash
./scripts/deploy-nixos-anywhere.sh thebeyond root@<ip> --build-on-remote
```

## References

- [nixos-anywhere Documentation](https://nix-community.github.io/nixos-anywhere/)
- [disko Documentation](https://github.com/nix-community/disko)
