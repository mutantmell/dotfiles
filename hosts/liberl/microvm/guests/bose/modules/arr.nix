{pkgs, ...}: let
  inherit (pkgs.mmell.lib.data.users) media mediaops;

  # Wrapper that forces umask 0002 so dirs/files filebot creates under
  # /media/library/<type>/ (setgid 2775, group=media via tmpfiles in nas.nix)
  # are group-writable. Without this, filebot inherits the operator's default
  # umask 0022 and produces group-readable-but-not-writable subdirs, which
  # then break Radarr/Sonarr's later Rename Files step with EACCES.
  filebot-ingest = pkgs.writeShellApplication {
    name = "filebot-ingest";
    runtimeInputs = [pkgs.filebot];
    text = ''
      umask 0002
      exec filebot "$@"
    '';
  };
in {
  users.groups.media.gid = media.gid;
  users.users.media = {
    inherit (media) uid;
    group = "media";
    isSystemUser = true;
  };

  # Role account for media-ingest tooling (FileBot, future beets/picard).
  # FileBot refuses to run as root by design, and tools that touch
  # /media/library/ need group=media for write access. su from root to
  # this account; no SSH keys (root SSH already gates entry). uid is
  # registry-coordinated so file ownership stays coherent if this user
  # is ever instantiated on additional ingest hosts.
  users.users.mediaops = {
    inherit (mediaops) uid;
    isNormalUser = true;
    group = "media";
    shell = pkgs.bashInteractive;
  };

  services.sonarr = {
    enable = true;
    group = "media";
  };
  services.radarr = {
    enable = true;
    group = "media";
    # Flatten dataDir to avoid nested .config parent getting root:root from
    # tmpfiles intermediate-parent creation (upstream module is asymmetric
    # vs sonarr, which uses StateDirectory).
    dataDir = "/var/lib/radarr";
  };
  services.bazarr = {
    enable = true;
    group = "media";
  };

  environment.systemPackages = [
    pkgs.filebot
    filebot-ingest
    pkgs.mediainfo
    pkgs.ffmpeg-headless
  ];

  # Deprioritize arr operations to avoid starving NAS workloads
  systemd.services.sonarr.serviceConfig = {
    Nice = 19;
    IOSchedulingClass = "idle";
    CPUWeight = 10;
  };
  systemd.services.radarr.serviceConfig = {
    Nice = 19;
    IOSchedulingClass = "idle";
    CPUWeight = 10;
  };

  environment.persistence."/persist" = {
    directories = [
      {
        directory = "/var/lib/sonarr";
        user = "sonarr";
        group = "media";
      }
      {
        directory = "/var/lib/radarr";
        user = "radarr";
        group = "media";
      }
      {
        directory = "/var/lib/bazarr";
        user = "bazarr";
        group = "media";
      }
    ];
  };
}
