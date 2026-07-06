{
  config,
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  h = net.hosts;
  inherit (pkgs.mmell.lib.data.users) media;
in {
  environment.systemPackages = with pkgs; [
    smartmontools
    jdupes
    ncdu
    rclone
    sshfs
  ];

  users.groups.media.gid = media.gid;
  users.users.media = {
    inherit (media) uid;
    group = "media";
    isSystemUser = true;
  };

  # Source-restricted firewall rules for NAS services
  networking.firewall.extraInputRules = ''
    # NFS from specific VM hosts only
    ip saddr { ${h.calvard.ipv4}, ${h.erebonia.ipv4} } tcp dport 2049 accept
    ip6 saddr { ${h.calvard.ipv6}, ${h.erebonia.ipv6} } tcp dport 2049 accept
  '';

  systemd.services.liberl-smb-zfs-properties = {
    description = "Apply Samba metadata properties to SMB-served ZFS datasets";
    after = ["zfs-mount.service"];
    wants = ["zfs-mount.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      zfs=${config.boot.zfs.package}/bin/zfs
      for dataset in data/media data/drive data/backup; do
        if "$zfs" list -H -o name "$dataset" >/dev/null 2>&1; then
          "$zfs" set xattr=sa acltype=posixacl "$dataset"
        fi
      done
    '';
  };

  # Bind mounts into the NFS export tree
  # Both RW and RO bind the same root (/data/media); access level is enforced by export options
  fileSystems = let
    media = {
      device = "/data/media";
      fsType = "none";
      options = ["bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service"];
    };
  in {
    "/export/rw/media" = media;
    "/export/ro/media" = media;
  };

  # Media tree permissions: 2775 (setgid + group-writable) so the arr stack
  # (sonarr/radarr/bazarr run as their own user with group=media) can write,
  # and so new subdirs created by any writer inherit group=media regardless
  # of the writer's primary group.
  systemd.tmpfiles.rules = let
    uid = toString media.uid;
    gid = toString media.gid;
    dir = path: "d ${path} 2775 ${uid} ${gid} -";
  in [
    (dir "/data/media")
    # Default tier (SD/1080p video, MP3 audio): managed by ravennue's
    # sonarr/radarr/lidarr.
    (dir "/data/media/library")
    (dir "/data/media/library/movies")
    (dir "/data/media/library/tv")
    # Derived view of TV for shows whose physical media follows a non-aired
    # ordering (Futurama: DVD order). Sonarr keeps `library/tv/` in canonical
    # airdate order; a derive script (TBD) hardlinks files into here under
    # the alternate ordering for Jellyfin to surface. No HQ equivalent yet
    # since no driving title needs it; add `library-hq/tv-curated/` when one
    # appears.
    (dir "/data/media/library/tv-curated")
    (dir "/data/media/library/music")
    # Software: games tree. console/ uses a platform/{type}/{gameDir} layout
    # where {type} comes from Igir (e.g. Retail, Hacks). Per-platform and
    # per-type dirs are created on demand by Igir / operator mkdir.
    (dir "/data/media/library/software")
    (dir "/data/media/library/software/console")
    (dir "/data/media/library/software/pc")
    # Staging: incoming/unverified source material, nested under a method
    # layer. `staging/manual/` replaces the former flat `manual/` tree;
    # future siblings (staging/torrents/, staging/usenet/) land here when
    # a downloader is wired up.
    (dir "/data/media/staging")
    (dir "/data/media/staging/manual")
    (dir "/data/media/staging/manual/movies")
    (dir "/data/media/staging/manual/tv")
    (dir "/data/media/staging/manual/music")
    (dir "/data/media/staging/manual/console")
    (dir "/data/media/staging/manual/romhacks")
    (dir "/data/media/staging/manual/pc")
    # HQ tier (2160p video, FLAC audio): managed by bose's
    # sonarr/radarr/lidarr. Split at the library level (rather than
    # `library/tv-hq/`) so per-tier ownership and Jellyfin library
    # boundaries are unambiguous, and so future curated/derived trees can
    # branch per-tier without colliding with the suffix. Name is `-hq`
    # rather than `-4k` so the same convention generalizes across video
    # (4K), audio (lossless), and any future media type.
    (dir "/data/media/library-hq")
    (dir "/data/media/library-hq/movies")
    (dir "/data/media/library-hq/tv")
    (dir "/data/media/library-hq/music")
    # HQ-tier staging: `staging-hq/manual/` replaces the former flat
    # `manual-hq/` tree. Inner dir is `manual/` (no `-hq` suffix — the
    # parent already signals tier).
    (dir "/data/media/staging-hq")
    (dir "/data/media/staging-hq/manual")
    (dir "/data/media/staging-hq/manual/movies")
    (dir "/data/media/staging-hq/manual/tv")
    (dir "/data/media/staging-hq/manual/music")
    (dir "/data/media/mister")
    (dir "/data/media/mister/games")
  ];

  services.nfs.server = {
    enable = true;
    # Per-host exports with UID squashing — no subnet-wide access, no root_squash bypass
    exports = let
      uid = toString media.uid;
      gid = toString media.gid;
    in ''
      /export/rw/media  ${h.erebonia.ipv4}(rw,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid}) ${h.erebonia.ipv6}(rw,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid})
      /export/ro/media  ${h.calvard.ipv4}(ro,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid}) ${h.calvard.ipv6}(ro,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid})
    '';
  };

  services.devmon.enable = true;
  services.udisks2.enable = true;
  boot.supportedFilesystems = ["ntfs"];

  power.ups = {
    enable = true;
    ups."apc" = {
      driver = "usbhid-ups";
      port = "auto";
      description = "APC UPS";
    };
    users.upsmon = {
      passwordFile = config.sops.secrets."upsmon.password".path;
      upsmon = "primary";
    };
    upsmon.monitor."apc".user = "upsmon";
  };
}
