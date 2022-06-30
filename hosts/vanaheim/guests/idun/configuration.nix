let
  hostname = "idun";
  cert = {
    filename = "idun.crt";
  };
  key = {
    filename = "idun.key";
  };
  credentials = {
    filename = "credentials";
  };
in { config, pkgs, ...}:
  {
    imports =
      [ # Include the results of the hardware scan.
        ./hardware-configuration.nix
      ];

    # Use the systemd-boot EFI boot loader.
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    
    networking.hostName = "${hostname}";
    
    networking.useDHCP = false;
    networking.interfaces.enp1s0.useDHCP = true;

    time.timeZone = "UTC";

    services.openssh.enable = true;
    services.openssh.passwordAuthentication = false;

    users.users = {
      root = {
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPoCCiFtZ//7igTH9ChEXLkUsA35xzX33ZkhPY0KOohO malaguy@gmail.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyEvg2vPwhxg72QgVjNzbzGd3eE0/ZjdoDawHoK24fR malaguy@gmail.com"
        ];
      };
    };
    
    networking.firewall = {
      allowedTCPPorts = [
        80
        443
        #6680
      ];
      allowedUDPPorts = [
        #6680
      ];
    };

    sound.enable = true;
    hardware.pulseaudio = {
      enable = true;
      systemWide = true;
    };

    fileSystems."/mnt/media" = rec {
      device = "//mimisbrunnr.yggd/media";
      fsType = "cifs";
      options = let
        automount_opts = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s";
      in ["${automount_opts},credentials=/etc/${credentials.filename}"];
    };

    services.mopidy = {
      enable = true;
      extensionPackages = with pkgs; [
        # mopidy-musicbox-webclient
        mopidy-local
        mopidy-iris
        mopidy-jellyfin
      ];
      configuration = ''
        [Logging]
        Color = true
        # verbosity = 3
        
        [http]
        enabled = true
        hostname = ::
        port = 6680
        
        [local]
        enabled = false
        media_dir = /mnt/media/music
      '';
      extraConfigFiles = [
        "/etc/mopidy/mopidy.jellyfin.conf"
      ];
    };

    services.nginx = {
      enable = true;

      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;

      virtualHosts."${hostname}" = {
        addSSL = true;
        sslCertificate = "/etc/${cert.filename}";
        sslCertificateKey = "/etc/${key.filename}";

        locations."= /" = {
          return = "301 /iris/";
          priority = 100;
        };
        
        locations."/" = {
          proxyPass = "http://localhost:6680";
          proxyWebsockets = true;
          priority = 200;
        };
      };
    };
  }
