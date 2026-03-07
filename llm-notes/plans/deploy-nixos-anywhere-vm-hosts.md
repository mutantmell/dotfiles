# Plan: Extend deploy-nixos-anywhere for VM Hosts

## Goal

Extend `scripts/deploy-nixos-anywhere.sh` to support deploying **erebonia** and **calvard** (vm-host profile), including automatic setup of microVM guest SSH keys/sops and Incus guest SSH keys/sops.

### Supported hosts after this work

| Host      | Profile | Disk         | Guests                                                                        |
| --------- | ------- | ------------ | ----------------------------------------------------------------------------- |
| thebeyond | router  | LUKS (disko) | phantasma (microVM)                                                           |
| erebonia  | vm-host | ZFS (disko)  | roer, legram, ordis, heimdallr, ymir, saint-arkh (microVM) + trista (Incus)   |
| calvard   | vm-host | ZFS (disko)  | edith, basel, tharbad, langport, oracion, creil (microVM) + messeldam (Incus) |

### Explicit non-goals

- OpenWrt devices, remiferia (NAS), raspberry pi, azoth
- Any host without a disko profile

---

## Part 1: Disko Profiles for VM Hosts

### 1a. Import the existing vm-host disko profile

`profiles/disko/vm-host.nix` already exists with the right layout (GPT + ESP + ZFS pool with encrypted datasets + tmpfs root). Both erebonia and calvard need to import it.

**erebonia/default.nix changes:**

```nix
imports = [
  ./hardware-configuration.nix
  (import ../../profiles/disko/vm-host.nix { disk = "/dev/sda"; })  # adjust device
  ./impermanence.nix
  ./microvm
  ./incus
];
```

**calvard/default.nix changes:**

```nix
imports = [
  ./hardware-configuration.nix
  (import ../../profiles/disko/vm-host.nix { disk = "/dev/nvme0n1"; })  # adjust device
  ./impermanence.nix
  ./microvm
  ./incus
];
```

The actual disk device names will need to be confirmed from the existing `hardware-configuration.nix` files. This is a deploy-time concern — the operator passes the correct device or we parameterize it.

### 1b. Update impermanence configs

Both hosts already use ZFS impermanence. Calvard is missing the `common.zfs.impermanence` stanza that erebonia has. Verify both have:

```nix
common.zfs.impermanence = {
  enable = true;
  dataset = "zroot/local/root";
};
```

**Note:** calvard's `impermanence.nix` currently lacks this — it relies on ZFS rollback being configured elsewhere or manually. Add it.

### 1c. Boot loader changes

Both hosts currently use `boot.loader.systemd-boot.enable = true`. The vm-host disko profile includes an EF02 GRUB boot partition, suggesting GRUB. However, the ESP partition (EF00) works with systemd-boot too.

**Decision:** Keep systemd-boot for the VM hosts. The EF02 partition in the disko profile is a legacy BIOS fallback — harmless but unused with systemd-boot. No boot loader changes needed.

---

## Part 2: Pin microvm User UID

### Why

The deploy script needs to create `/persist/guests/<name>/static` directories owned by `microvm:kvm` _before_ the first NixOS boot. Without a stable UID, the microvm user's ID is auto-assigned and might differ from what was used during deployment.

### What needs pinning

- **microvm user UID:** Currently auto-assigned (`uid = null` in the microvm module). Pin to **300**.
- **kvm group GID:** Already **302** system-wide — hardcoded in `nixos/modules/misc/ids.nix`. No pinning needed.

### Approach

Add to each vm-host config (or a shared module):

```nix
users.users.microvm.uid = 300;
```

The microvm module already creates the user with `isSystemUser = true` and `group = "kvm"`. We're just adding the UID. NixOS option merging handles this cleanly — confirmed by reading the microvm module source.

The deploy script will use `chown 300:302` for guest directories in extra-files.

### Where to put it

**Option A:** Add `users.users.microvm.uid = 300;` directly to each vm-host's microvm/default.nix.
**Option B:** Create a shared module that all microvm hosts import.

Option A is simpler and there are only 3 hosts (thebeyond, erebonia, calvard). Go with Option A.

---

## Part 3: Extend the Deploy Script

### 3a. Host-type detection

The script needs to know whether a host uses the router or vm-host profile to determine:

- Disk encryption method (LUKS keyfile vs ZFS passphrase)
- Phase 2 behavior (/nix bind mount vs ZFS datasets handle this natively)
- Post-install steps (LUKS keyfile copy vs ZFS passphrase save)
- Guest setup (microVM guests, Incus guests, or both)

**Approach:** Add a host metadata lookup. Options:

1. **Convention-based:** Detect from the host's Nix config (e.g., check if disko profile is router vs vm-host).
2. **Explicit map in the script:** Simple associative array.

Go with option 2 — it's straightforward and the number of supported hosts is small:

```bash
declare -A HOST_PROFILES=(
  [thebeyond]="router"
  [erebonia]="vm-host"
  [calvard]="vm-host"
)

PROFILE="${HOST_PROFILES[$HOSTNAME]:-}"
if [[ -z "$PROFILE" ]]; then
    echo "Error: Unknown host '$HOSTNAME'. Supported hosts: ${!HOST_PROFILES[*]}"
    exit 1
fi
```

### 3b. ZFS passphrase handling for vm-hosts

For vm-host profile:

1. **Generate/reuse a ZFS passphrase** (stored in `.keys/<hostname>-zfs.passphrase`)
2. **Pass it to disko** via nixos-anywhere's `--disk-encryption-keys /tmp/secret.key <passphrase-file>`
   - The vm-host disko profile currently uses `keylocation = "prompt"`. We need to temporarily set `keylocation = "file:///tmp/secret.key"` during disko, OR change the profile to accept a keyfile.
   - **Better approach:** Modify `profiles/disko/vm-host.nix` to use `keylocation = "file:///tmp/secret.key"` and `keyformat = "passphrase"`. This works because disko reads the passphrase from the file during formatting. After first boot, the host's `common.zfs.remoteUnlock` handles unlocking via SSH prompt (ZFS allows changing keylocation post-creation).
3. **No Phase 4** (no keyfile copy to /boot) — the passphrase is entered interactively on each boot via SSH remote unlock.

**vm-host disko profile change:**

```nix
zpool.zroot = {
  # ...
  rootFsOptions = {
    encryption = "on";
    keyformat = "passphrase";
    keylocation = "file:///tmp/secret.key";  # Used during disko format only
    # After first boot, operator can change to prompt:
    #   zfs set keylocation=prompt zroot
    # Or leave as-is if SSH remote unlock handles it.
    compression = "zstd";
    mountpoint = "none";
  };
};
```

Actually, on reflection: the remote unlock in initrd uses `systemd-tty-ask-password-agent` which prompts for the ZFS passphrase regardless of `keylocation`. The ZFS import in initrd triggers a password prompt when `keylocation=prompt`. Let's keep `keylocation = "prompt"` in the profile and instead pipe the passphrase during the disko phase:

**Revised approach:** nixos-anywhere's `--disk-encryption-keys` copies a file to the target. The disko ZFS handler reads from `keylocation`. If `keylocation = "prompt"`, disko will prompt interactively during formatting. We can't easily pipe to that.

**Simplest solution:** Change the disko profile to accept an optional `key-file` parameter:

```nix
{
  disk ? "/dev/sda",
  tmpfs-size ? "2G",
  key-file ? "/tmp/secret.key",
  ...
}:
```

And set `keylocation = "file://${key-file}"` during formatting. After disko completes and the pool is imported, the deploy script SSHs in and runs `zfs set keylocation=prompt zroot` so that subsequent boots require the interactive passphrase.

### 3c. Phase adjustments for vm-hosts

**Router profile (existing):**

1. Phase 1: kexec + disko (LUKS)
2. Phase 2: `/nix` bind mount on persistent storage
3. Phase 3: Install with extra-files (SSH key)
4. Phase 4: Copy LUKS keyfile to /boot/secrets
5. Phase 5: Fetch hardware-config

**VM-host profile (new):**

1. Phase 1: kexec + disko (ZFS)
   - nixos-anywhere copies passphrase file via `--disk-encryption-keys`
2. Phase 2: Set keylocation to prompt
   - `ssh $TARGET 'zfs set keylocation=prompt zroot'`
   - ZFS datasets handle /nix natively (dataset `local/nix` mounted at `/nix`), so no bind mount needed
3. Phase 3: Install with extra-files (SSH key)
   - Same as router — SSH host key placed in `/persist/etc/ssh/`
4. Phase 4: Set up guest infrastructure (see Parts 4 and 5)
5. Phase 5: Fetch hardware-config

### 3d. SSH host key and sops handling

No changes needed — the existing SSH key generation, age derivation, and sops re-encryption logic works identically for all host types.

---

## Part 4: MicroVM Guest Setup

After the host is installed (Phase 3), the deploy script sets up each microVM guest.

### 4a. Discover guests from the Nix config

The script needs to know which guests a host has. Options:

1. **List directories:** `ls hosts/$HOSTNAME/microvm/guests/`
2. **Nix eval:** `nix eval .#nixosConfigurations.$HOSTNAME.config.microvm.vms --apply builtins.attrNames`

Option 1 is simpler and doesn't require a full Nix eval. Use it.

```bash
GUEST_DIR="$REPO_ROOT/hosts/$HOSTNAME/microvm/guests"
if [[ -d "$GUEST_DIR" ]]; then
    MICROVM_GUESTS=$(ls "$GUEST_DIR")
fi
```

### 4b. For each microVM guest

For each guest in `$MICROVM_GUESTS`:

1. **Generate or reuse SSH host key:**

   ```bash
   GUEST_SSH_KEY="$KEYFILE_DIR/${guest}-ssh_host_ed25519_key"
   if [[ -f "$KEYS_DIR/${guest}-ssh_host_ed25519_key" ]]; then
       cp "$KEYS_DIR/${guest}-ssh_host_ed25519_key" "$GUEST_SSH_KEY"
       cp "$KEYS_DIR/${guest}-ssh_host_ed25519_key.pub" "$GUEST_SSH_KEY.pub"
   else
       ssh-keygen -t ed25519 -f "$GUEST_SSH_KEY" -q -N ""
   fi
   ```

2. **Place SSH key in extra-files for virtiofs share:**

   ```bash
   mkdir -p "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh"
   cp "$GUEST_SSH_KEY" "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key"
   cp "$GUEST_SSH_KEY.pub" "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key.pub"
   chmod 600 "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key"
   ```

3. **Create images directory:**
   The microvm module expects `/var/lib/microvms` (persisted to `/persist/var/lib/microvms`). Volume images go in `/persist/guests/<name>/images/`. The images are created by the microvm service on first start if they don't exist, so we just need the directory structure.

   ```bash
   # Directories in extra-files will be created on the target at install time
   mkdir -p "$EXTRA_FILES_DIR/persist/guests/${guest}/images"
   ```

   **Ownership:** These directories need `microvm:kvm` ownership. With pinned IDs (Part 2), we can `chown` by UID/GID in the extra-files, or set ownership via a post-install SSH command:

   ```bash
   ssh "$TARGET" "chown -R 300:302 /mnt/persist/guests/"
   ```

   Actually, the `static/` directory should be owned by `root:root` (SSH keys are root-owned), and the `images/` directory by `microvm:kvm`. Handle this with targeted chowns:

   ```bash
   ssh "$TARGET" bash -c "'
     for guest_dir in /mnt/persist/guests/*/; do
       chown -R root:root \"\$guest_dir/static\"
       chown 300:302 \"\$guest_dir/images\" 2>/dev/null || true
     done
   '"
   ```

4. **Derive age key and update .sops.yaml:**

   ```bash
   GUEST_AGE_KEY=$(ssh-to-age < "$GUEST_SSH_KEY.pub")
   GUEST_ANCHOR="&sv_${guest}"
   # Same logic as host key update — sed the anchor in .sops.yaml
   ```

5. **Ensure creation_rules exist in .sops.yaml:**
   The script should check if a creation rule exists for the guest's secrets path. If not, add one. The pattern is:

   ```yaml
   - path_regex: hosts/<parent>/microvm/guests/<guest>/secrets/[^/]+\.yaml$
     key_groups:
       - age:
         - *ad_denai
         - *sv_<guest>
   ```

   **Note:** The current `.sops.yaml` has inconsistent path patterns — some say `hosts/calvard/guests/` (wrong, should be `hosts/calvard/microvm/guests/`). This needs cleanup as part of this work.

6. **Re-encrypt guest secrets:**

   ```bash
   GUEST_SECRET_FILES=$(find "$REPO_ROOT/hosts/" -path "*${guest}*/secrets/*.yaml" 2>/dev/null || true)
   if [[ -n "$GUEST_SECRET_FILES" ]]; then
       echo "$GUEST_SECRET_FILES" | while read -r f; do
           sops updatekeys --yes "$f"
       done
   fi
   ```

7. **Backup keys:**
   ```bash
   cp "$GUEST_SSH_KEY" "$KEYS_DIR/${guest}-ssh_host_ed25519_key"
   cp "$GUEST_SSH_KEY.pub" "$KEYS_DIR/${guest}-ssh_host_ed25519_key.pub"
   ```

### 4c. Handling guests without secrets

Not all guests have sops secrets (some may have empty or placeholder `secrets.yaml`). The script should:

- Always generate SSH keys (every guest needs host identification)
- Always update `.sops.yaml` age keys (needed if secrets are added later)
- Only run `sops updatekeys` if secret files exist

---

## Part 5: Incus Guest Setup

### 5a. Discover Incus guests

Similar to microVM guests, discover from directory structure:

```bash
INCUS_GUEST_DIR="$REPO_ROOT/hosts/$HOSTNAME/incus/guests"
if [[ -d "$INCUS_GUEST_DIR" ]]; then
    INCUS_GUESTS=$(ls "$INCUS_GUEST_DIR")
fi
```

### 5b. For each Incus guest

1. **Generate or reuse SSH host key** (same pattern as microVM guests)

2. **Derive age key and update .sops.yaml** (same pattern)

3. **Add creation_rules to .sops.yaml** if missing:

   ```yaml
   - path_regex: hosts/<parent>/incus/guests/<guest>/secrets/[^/]+\.yaml$
     key_groups:
       - age:
         - *ad_denai
         - *sv_<guest>
   ```

4. **Backup keys** (same pattern)

5. **Push SSH key to running VM after boot:**
   Incus VMs generate their own SSH keys on first boot. We need to replace those with our pre-generated keys. This happens _after_ the host has booted and Incus VMs are running.

   The deploy script should output instructions (not automate this part in the main flow) since the Incus VMs won't be running until the host boots and the activation script creates/starts them:

   ```
   Post-boot Incus guest setup:
     For each Incus guest, SSH to the host and run:
       incus file push <key> <guest>/etc/ssh/ssh_host_ed25519_key --uid=0 --gid=0 --mode=0600
       incus file push <key>.pub <guest>/etc/ssh/ssh_host_ed25519_key.pub --uid=0 --gid=0 --mode=0644
       incus exec <guest> -- systemctl restart sshd
   ```

   **Alternative (preferred):** Create a post-boot script that the operator runs after first host boot:

   ```bash
   # scripts/setup-incus-guests.sh <hostname>
   # SSHs to the host and pushes SSH keys to each Incus VM
   ```

   This is cleaner than trying to do it inline in the deploy script, since the host must be fully booted with Incus running first.

### 5c. Incus guest sops.nix setup

Currently, Incus guests (messeldam, trista) have no sops.nix. To enable sops for them:

1. Create `sops.nix` in each Incus guest config directory:

   ```nix
   {
     sops = {
       defaultSopsFile = ./secrets/secrets.yaml;
       age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
       secrets = {
         # Add secrets as needed
       };
     };
   }
   ```

2. Import `./sops.nix` in the guest's `default.nix`.

3. Create placeholder `secrets/secrets.yaml` files.

**Note:** This is a NixOS config change, not a deploy script change. It should be done as a prerequisite commit before the deploy script changes.

---

## Part 6: .sops.yaml Cleanup

### Current issues

1. **Wrong path patterns:** `hosts/calvard/guests/heimdallr/` should be `hosts/calvard/microvm/guests/heimdallr/` (if heimdallr is a microVM guest on calvard) or may be stale from the rename.
2. **Missing entries:** No creation rules for new calvard guests (edith, basel, tharbad, langport, oracion, creil).
3. **Missing keys:** No `&sv_edith`, `&sv_basel`, etc. in the keys section.

### Fix

The deploy script will add missing keys and creation rules automatically. But the existing wrong paths should be cleaned up in a prerequisite commit.

---

## Implementation Order

### Phase A: Prerequisites (NixOS config changes)

1. **Pin microvm/kvm IDs** — Create `modules/common/microvm-ids.nix` or add to each vm-host config
2. **Import disko profile** — Add `(import ../../profiles/disko/vm-host.nix { ... })` to erebonia and calvard
3. **Add ZFS impermanence** to calvard (erebonia already has it)
4. **Update vm-host disko profile** — Add `key-file` parameter for passphrase file during formatting
5. **Fix .sops.yaml paths** — Correct the path_regex patterns for existing guests
6. **Add sops.nix to Incus guests** — messeldam, trista
7. **Create placeholder secrets** for Incus guests

### Phase B: Deploy script changes

1. **Add host profile map** and profile-conditional logic
2. **Add ZFS passphrase flow** for vm-host profile (generate/reuse passphrase, pass to disko, set keylocation=prompt after format)
3. **Add microVM guest loop** — SSH key generation, extra-files placement, sops integration
4. **Add Incus guest loop** — SSH key generation, sops integration, .sops.yaml updates
5. **Add post-install ownership fixup** — chown guest directories with pinned UIDs
6. **Create `scripts/setup-incus-guests.sh`** — Post-boot script to push SSH keys to Incus VMs

### Phase C: Testing

1. **Dry-run validation:** Run `nix flake check` to verify NixOS config changes don't break anything
2. **Script validation:** Run the deploy script with `--help` / early-exit to verify profile detection
3. **Deploy to calvard** (new machine, safe to test)
4. **Deploy to erebonia** (after calvard succeeds)

---

## Resolved Questions

### 1. Disk device names

From the hardware-configuration.nix files:

- **erebonia:** Uses SATA (`ahci` module), ESP at `/dev/disk/by-uuid/CB34-6457`. The primary disk is likely `/dev/sda`. The interface is `eno1`.
- **calvard:** Uses NVMe (`nvme` module), ESP at `/dev/disk/by-uuid/D757-F359`. The primary disk is likely `/dev/nvme0n1`. The interface is `enp88s0`. Already has tmpfs root.

**Decision:** The disko profile's `disk` parameter will be set at import time. The deploy script doesn't need to know — it's baked into the NixOS config. The operator must verify the correct device before deploying (the disko profile parameterizes this in the host's `default.nix`).

### 2. ZFS keylocation lifecycle — CONFIRMED WORKING

The NixOS ZFS initrd module (in `nixos/modules/tasks/filesystems/zfs.nix`) explicitly handles `keylocation=prompt`:

```bash
case "$kl" in
  prompt )
    systemd-ask-password --timeout=... "Enter key for $ds:" | zfs load-key "$ds"
    ;;
esac
```

The `common.zfs.remoteUnlock` module provides SSH in initrd with `systemd-tty-ask-password-agent`, which relays the `systemd-ask-password` prompts over the SSH session. This works correctly with `keylocation=prompt`.

**Lifecycle:**

1. disko creates pool with `keylocation=file:///tmp/secret.key` (passphrase in temp file)
2. Deploy script runs `zfs set keylocation=prompt zroot` after disko completes
3. Subsequent boots: initrd detects `keystatus=unavailable`, sees `keylocation=prompt`, uses `systemd-ask-password`
4. Operator SSHs to port 2222 and `systemd-tty-ask-password-agent` relays the prompt

`boot.zfs.requestEncryptionCredentials` defaults to `true`, so no extra config needed.

### 3. Existing ZFS data — DESTRUCTIVE OPERATION WARNING

Deploying with disko **will destroy all existing data** on the target disk. The deploy script must:

- Print a prominent warning for vm-host profile deployments
- Require explicit confirmation (separate from the general deploy confirmation)
- Mention that erebonia has existing ZFS pools with microVM guest data

### 4. microvm module UID behavior — SAFE TO OVERRIDE

The microvm module (from `github:astro/microvm.nix`) creates the `microvm` user with `uid = null` (auto-assigned) and `group = "kvm"`. Setting `users.users.microvm.uid = 300` in our config cleanly overrides via NixOS option merging — no conflict.

The `kvm` group is defined by NixOS itself with **GID 302** (hardcoded in `nixos/modules/misc/ids.nix`). We do NOT need to pin it — it's already stable across all NixOS systems.

**Revised approach for Part 2:**

- Pin only `users.users.microvm.uid = 300`
- Do NOT pin `users.groups.kvm.gid` — it's already 302 system-wide
- Use UID 300 and GID 302 for chown operations in the deploy script

### 5. Incus guest SSH key replacement — POST-BOOT WORKFLOW

After `incus file push` replaces the SSH key:

1. `systemctl restart sshd` on the guest to pick up the new host key
2. If sops-nix is configured, run `nixos-rebuild switch` on the guest to trigger sops activation (decrypts secrets using the new key)
3. The `setup-incus-guests.sh` script should handle all three steps: push key, restart sshd, trigger rebuild

### 6. creil guest — NEEDS SSH KEY SETUP, NO SOPS YET

creil (Forgejo Actions runner on calvard) has:

- SSH host key at `/static/etc/ssh/ssh_host_ed25519_key` (standard microVM pattern)
- `common.openssh.enable = true`
- No `sops.nix` — no encrypted secrets currently
- No `secrets/` directory

**Decision:** Generate SSH key for creil (it needs host identification for SSH), add `&sv_creil` to `.sops.yaml` keys section (for future use), but no creation rule needed until secrets are added.
