{pkgs, ...}: let
  inherit (pkgs.mmell.lib.data.users) media mediaops;

  # Wrappers force umask 0002 so files/dirs written into the setgid 2775
  # media trees are group-writable. Without this, tools inherit the operator's
  # default umask 0022, producing group-readable-but-not-writable output that
  # breaks later re-ingestion or Radarr/Sonarr rename steps with EACCES.
  filebot = pkgs.writeShellApplication {
    name = "filebot";
    runtimeInputs = [pkgs.filebot];
    text = ''
      umask 0002
      exec filebot "$@"
    '';
  };

  beet = pkgs.writeShellApplication {
    name = "beet";
    runtimeInputs = [pkgs.beets];
    text = ''
      umask 0002
      exec beet "$@"
    '';
  };

  igir = pkgs.writeShellApplication {
    name = "igir";
    runtimeInputs = [pkgs.igir];
    text = ''
      umask 0002
      exec igir "$@"
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
  services.lidarr = {
    enable = true;
    group = "media";
  };

  environment.systemPackages = [
    filebot
    pkgs.mediainfo
    pkgs.ffmpeg-headless
    pkgs.picard
    beet
    igir
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
  systemd.services.lidarr.serviceConfig = {
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
      {
        directory = "/var/lib/lidarr";
        user = "lidarr";
        group = "media";
      }
    ];
  };
}
