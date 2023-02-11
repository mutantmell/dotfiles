let
  hostname = "bragi";
in { config, pkgs, ...}:
{
  imports =
    [
      ./hardware-configuration.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "${hostname}";

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    MaxFileSec=7day
  '';

  time.timeZone = "UTC";

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;

  users.users = {
    root = {
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPoCCiFtZ//7igTH9ChEXLkUsA35xzX33ZkhPY0KOohO malaguy@gmail.com"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
      ];
    };
  };
  
  environment.etc = {
    "step-ca/data/intermediate_ca.crt" = {
      source = ../../../../common/data/intermediate_ca.crt;
      mode = "0444";
    };
  };
  security.acme = {
    defaults = {
      server = "https://alfheim.local/acme/acme/directory";
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
  };
  security.pki.certificates = [ (builtins.readFile ../../../../common/data/root_ca.crt) ];

  networking.firewall = {
    allowedTCPPorts = [
      80
      443
      8096
    ];
    allowedUDPPorts = [
      1900
      7359
    ];
  };

  users.users = {
    jellyfin = {
      uid = 1000;
    };
  };

  fileSystems."/mnt/media" = {
    device = "/media";
    fsType = "9p";
    options = [ "trans=virtio" "version=9p2000.L" ];
  };

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  services.jellyfin = {
    enable = true;
  };

  services.nginx = {
    enable = true;

    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;

    virtualHosts."${hostname}.local" = let
      jellyfinConf = ''
        add_header X-Frame-Options "SAMEORIGIN";
        add_header X-XSS-Protection "1; mode=block";
        add_header X-Content-Type-Options "nosniff";

        add_header Strict-Transport-Security "max-age=31536000" always;

        # Content Security Policy
        # See: https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP
        # Enforces https content and restricts JS/CSS to origin
        # External Javascript (such as cast_sender.js for Chromecast or YouTube embed JS for external trailers) must be whitelisted.
        add_header Content-Security-Policy "default-src https: data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' https://www.gstatic.com/cv/js/sender/v1/cast_sender.js https://www.youtube.com/iframe_api https://s.ytimg.com; worker-src 'self' blob:; connect-src 'self'; object-src 'none'; frame-ancestors 'self'";
      '';
    in {
      forceSSL = true;
      enableACME = true;

      extraConfig = ''
        proxy_read_timeout 604800;
        proxy_send_timeout 604800;
      '';

      locations."/socket" = {
        proxyPass = "http://localhost:8096/socket";
        extraConfig = jellyfinConf;
      };
      locations."/" = {
        proxyPass = "http://localhost:8096";
        extraConfig = jellyfinConf;
      };
    };
  };

  system.stateVersion = "22.11";
}
