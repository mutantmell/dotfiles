# Managed clients and existing workstation substrates

Angbar (laptop), kernviter (WSL) and arcus (Steam Deck) are client systems; host names and roles are listed in [hostnames](hostnames.md). The laptop/WSL installation sequences are historical, but Angbar’s VPN setup and remote acceptance remain unverified; the router peer declaration does not establish a working client. Keep hardware/WSL details in the active host modules and follow current Authelia SSH-certificate guidance rather than their Keycloak-era commands.

Edith and trista remain Incus guests in this checkout. Incus image building uses the repository's disko integration; old disk-full recovery stories are not instructions to recreate a healthy guest. Back up state and identify the current backing disk/filesystem before any rescue operation. A move to persistent KubeVirt VMs remains proposed and must preserve their full mutable-workstation behavior. See [deferred decisions](design/deferred-decisions.md) and the workstation issues.

Do not remove Incus modules, images, secrets or provisioning support until both workload and recovery consumers are retired. Guest identities remain independent of the intended substrate; operator private keys must not enter generated images or issue attachments.

[Angbar VPN acceptance](https://forgejo.internal/mutantmell-net/dotfiles/issues/237) first inventories any existing operator-managed NetworkManager profile, then verifies or completes offsite routing/DNS/reconnect behavior. Keep the current manual client if it already meets the intended contract; record its recovery procedure rather than claiming the absence of Nix settings proves it is unused.

The persistent workstation migration follows the [selected ownership and private bootstrap contract](design/workstation-lifecycle.md), including explicitly enrolled in-guest Comin and old/new instance safeguards.

## Incus guest recovery while Incus remains in service

Use this only for a guest that cannot be repaired in place, on its actual parent
(calvard for edith, erebonia for trista). Identify the backing disk/filesystem,
current deployed configuration and all mutable state first. Recreating an instance
loses its root disk, including homes, databases and logs. `/home` alone is not a
complete backup. Preserve required additional state and verify restoration from
a copy stored outside the instance before approving deletion.

When the guest agent is reachable, `incus exec` uses vsock even if guest networking
is broken. As root on the parent, capture a private backup to durable operator
storage (replace the example name/path):

```bash
guest_name=edith
backup_file=/path/to/private-backup/edith-home.tar
incus exec "$guest_name" -- tar cf - /home > "$backup_file"
tar tf "$backup_file" >/dev/null
```

Check the command exit status, archive contents and a trial extraction; a listing
alone does not prove a complete backup. If the agent/root disk is inaccessible,
stop here and recover from the disk or another verified backup. Host-side
`/persist/guests/<name>/static/` contains identities mounted at `/static`; verify
and privately back up that directory separately. Do not delete or regenerate it.
Never attach these archives or keys to an issue.

After verified backups and the operator's destructive-recovery decision:

1. Stop and delete only the broken instance (`incus stop <name>`, then
   `incus delete <name>`). Inspect its image alias before removing a stale image
   with `incus image delete <name>`; do not remove a shared image blindly.
2. If removing that alias, also remove its stale source marker
   `/var/lib/incus/.image-source-<name>`: the ensure script otherwise considers
   the missing image current. Deploy the reviewed parent configuration if needed
   using the normal deployment procedure.
3. Run `incus-ensure-instances` on the parent to import the declared image and
   recreate the guest, then `incus-update-instance <name>` to transfer/activate
   its current system closure. These helpers reconcile managed guests; inspect
   their journal and changes to other guests.
4. Restore the home archive with
   `incus exec <name> -- tar xf - -C / < /path/to/private-backup/<name>-home.tar`,
   then restore the separately backed-up application state with its own procedure.
5. Verify identity fingerprints, ownership, guest IP/routes, services and user data.
   Restart with `incus restart <name>` and repeat connectivity/persistence checks.

The helper behavior is defined in `modules/incus/default.nix`; guest static-path
ownership is coordinated by `modules/common/incus.nix`. The old ext4 corruption
incident does not establish that a current disko-built guest has that failure.
