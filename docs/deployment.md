# Initial NixOS installation and operator recovery

This describes `scripts/deploy-nixos-anywhere.sh`, not ongoing unattended updates.
[Comin delivery](host-pull-updates.md) is still planned. Installation destroys
the configured target disks, including guest data on them. Back up required
state and confirm the host's disko device identities before running it.

## Prerequisites

Use an operator environment with Nix flakes, SSH, jq, ssh-keygen, age-keygen
with PQ support, sops, OpenSSL and passage. The script checks these tools.
The target needs reachable SSH/root installation access and a supported Linux
kexec environment. Confirm console/recovery access and network connectivity.

The wrapper supports its LUKS-backed tmpfs/XFS and btrfs profile shapes, derived
from `nixosConfigurations.<host>.config.disko.devices.disk.main.content.partitions`.
It rejects an unsupported profile. Review the current host output before choosing
a target. Extra arguments are passed to both nixos-anywhere phases.

```bash
./scripts/deploy-nixos-anywhere.sh thebeyond root@192.168.1.100
```

The wrapper asks for the exact hostname to confirm disk destruction, then asks
for final deployment confirmation. It can update public key registry data before
those prompts; review the working tree even if cancelling.

## Identities and encrypted state

Passage is the authoritative operator store for reusable private bootstrap keys:

| Entry under `hosts/<host>/` | Purpose                             | Installed location                          |
| --------------------------- | ----------------------------------- | ------------------------------------------- |
| `disk.key`                  | LUKS keyfile                        | `/boot/secrets/disk.key`                    |
| `ssh_host_ed25519_key`      | SSH host identity                   | `/persist/etc/ssh/ssh_host_ed25519_key`     |
| `age.key`                   | Native PQ age identity for sops-nix | `/persist/var/lib/sops-nix/key.txt`         |
| `fleet_enrollment_key`      | Fleet X5C enrollment identity       | `/persist/var/lib/fleet-tls/enrollment.key` |

Existing entries are reused; missing identities are generated and stored by the
wrapper. Temporary staging prefers `/dev/shm`, with a temporary-directory fallback
and exit cleanup. Do not place private key copies in Git or issue attachments.
The old `.keys/<host>-disk.key` and post-install scp workflow is retired.

The wrapper updates public SSH/enrollment data in `lib/common/data/keys.json`,
updates an existing `&sv_<host>` age anchor in `.sops.yaml`, and runs
`sops updatekeys` on host secret YAML. A missing anchor requires an operator edit
to keys/creation_rules. The host's PQ recipient must use compatible admin
recipients; mixed classical/PQ rules can fail. Review the emitted warning and
stop to fix the rule rather than treating re-encryption failure as success.

MicroVM and Incus guest directories are discovered under the host.
`setup-guest.sh` prepares their identities and static trees into the private
extra-files staging directory. [Host identity](host-identity.md) documents the
bootstrap boundaries. The wrapper attempts SSH host and fleet enrollment
certificate signing when operator CA material is available. It reports unsigned
hosts at the end; absence of signing material is not proof enrollment succeeded.

## Installation phases

1. Run nixos-anywhere kexec/disko with the selected flake and LUKS key.
2. For tmpfs, bind persistent `/nix` into the installation root. For btrfs,
   create the read-only `@blank` snapshot used by impermanence.
3. Run nixos-anywhere install with `--extra-files` so host/guest identities and
   `/boot/secrets/disk.key` are available on first boot. The wrapper does not
   require a post-install SSH copy of the disk key.

Read the current script before rerunning after a partial failure: it is an
installation wrapper and its disk-formatting phase is destructive. Reusing
identities from passage does not make reinstalling disks non-destructive.

## After installation

Reboot when ready, verify the expected SSH host identity and automatic LUKS
unlock, and check sops-nix without printing secret contents. Fetch hardware
configuration with `nixos-generate-config --no-filesystems --show-hardware-config`
from the installed host; review it against disko before committing. Review all
public registry/certificate, encrypted-secret and `.sops.yaml` changes.

For reported unsigned identities, use the existing operator signing entrypoints:

```bash
nix run .#ssh-host-cert-sign -- --sign <hostname>
nix run .#fleet-x5c-cert-sign -- --sign <hostname>
```

Commit public certificates and rebuild/redeploy as required, then verify actual
fleet enrollment and guest startup. Keep the passage recovery material outside
the target's failure domain. [Secrets](secrets.md), [router deployment](router-deployment.md)
and [host identity](host-identity.md) cover related operator work.
