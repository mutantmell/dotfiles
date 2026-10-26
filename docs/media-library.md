# Media library layout and ownership

`hosts/liberl/nas.nix` defines the storage/export layout; bose and ravennue write through the media mount while oracion serves read-only consumers. Keeping incoming and library paths in one filesystem permits hardlink imports. A child ZFS dataset or mismatched NFS mount can silently break that property.

Default video goes to `library/{movies,tv}`, HQ video to `library-hq/{movies,tv}`. ravennue owns the default arr instances; bose owns HQ arrs and Bazarr. Both guests already have Lidarr instances; the old dual-instance installation follow-up is superseded by code. FileBot pre-renaming runs on bose as `mediaops`; it is not the old mnamer workflow. Jellyfin/Navidrome/Retrom on oracion consume organized libraries.

Incoming paths are `staging/manual/` and `staging-hq/manual/`, replacing flat `manual/` and `manual-hq/`. Console software is DAT/Igir-managed under `library/software/console`; PC software is curated folder-per-game under `library/software/pc`. Console type directories distinguish retail, hacks, and translations without separate library roots. MISTer is a peer view outside the serving-library tree; validate its links after moves.

The current NAS directories and Retrom console/PC scan roots already use this layout; Ruan already enables MISTer symlink support. Do not repeat that implementation. Tmpfiles does not move old contents, Retrom configuration does not remove old database platforms, and Samba does not create view links. Inventory residual data and application-managed state when carrying out the migration issues; if none remains, those tasks are complete. Migrate only remaining data with backups, preserving inodes and avoiding overwrite collisions when collapsing old PC directories. [Media ingestion](media-ingestion.md) covers recurring import and verification. The removed large media and music plans are historical rollout detail, not instructions to rebuild the NAS.

## Curated TV: selected deferred work

`library/tv-curated/` is declared, but its derive tool and Jellyfin library wiring are not implemented. Sonarr owns `library/tv/` in canonical airdate order. A bounded operator-mapped derive tool should own only hardlinks/metadata it generates in the alternate view, preserving canonical filenames and arr matching. Reconcile updates and remove stale generated links without deleting canonical files. Hardlinks share content: modifying the view’s file modifies the source inode, so serve the view read-only and do not treat it as a backup.

Resume with a concrete title/order mapping through [the curated-TV issue](https://forgejo.internal/mutantmell-net/dotfiles/issues/271). Validate DVD/absolute-order metadata and decide which Jellyfin libraries expose canonical versus curated episodes to avoid unintended duplicates. An HQ counterpart remains deferred until a title needs it.

Jellyfin’s directory authentication is operator-managed; [the LDAP reconstruction runbook](jellyfin-ldap.md) preserves connection, membership, local-admin and recovery procedures.
