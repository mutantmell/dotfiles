{ config, pkgs, ...}:

{
  imports = [
    ./microvm.nix
  ];

  networking.hostName = "bragi";

  nixpkgs.overlays = [(final: prev: {
    vaapiIntel = prev.vaapiIntel.override { enableHybridCodec = true; };
  })];

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:45:07:58:F0:82";
    networkConfig = {
      Address = [ "10.0.100.50/24" ];
      Gateway = "10.0.100.1";
      DNS = [ "10.0.100.1" ];
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };
  networking.extraHosts = ''
    10.0.10.2 alfheim.local
  '';

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vaapiIntel
      vaapiVdpau
      libvdpau-va-gl
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
    ];
  };

  time.timeZone = "UTC";

  common.openssh.enable = true;

  environment.etc = {
    "step-ca/data/intermediate_ca.crt" = {
      source = pkgs.mmell.lib.data.certs.intermediate;
      mode = "0444";
    };
  };
  security.acme = {
    defaults = {
      server = "https://alfheim.local/acme/acme/directory"; # TODO: change to new server once that's all working
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
    certs."${config.networking.hostName}.local" = {
      group = "acme-cert";
    };
  };
  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];
  systemd.services."jellyfin-cert-renew" = {
    serviceConfig.Type = "oneshot";
    description = "Mangage Jellyfin's pkcs12 key";
    path = with pkgs; [ bash openssl ];
    script = let
      acmedir = "/var/lib/acme/${config.networking.hostName}.local";
      jellydir = config.systemd.services.jellyfin.serviceConfig.WorkingDirectory;
    in ''
      #!/usr/bin/env bash

      openssl pkcs12 -export -out ${jellydir}/key.pfx -inkey ${acmedir}/key.pem -in ${acmedir}/cert.pem  -passout pass:
      chmod 640 ${jellydir}/key.pfx
      chown acme:acme-cert ${jellydir}/key.pfx
    '';
    wantedBy = [ "acme-${config.networking.hostName}.local.service" ];
    after = [ "acme-${config.networking.hostName}.local.service" ];
  };

  networking.firewall = {
    allowedTCPPorts = [
      80
      443
      8096
      8920
    ];
    allowedUDPPorts = [
      1900
      5353
      7359
    ];
  };

  users.users = {
    jellyfin = {
      uid = 1000;
      extraGroups = ["acme-cert"];
    };
    nginx.extraGroups = [ "acme-cert" ];
  };
  users.groups."acme-cert" = {};

  services.jellyfin = {
    enable = true;
  };

  services.nginx = {
    enable = true;

    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;

    virtualHosts."${config.networking.hostName}.local" = let
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
        proxyPass = "http://127.0.0.1:8096/socket";
        extraConfig = ''
          ${jellyfinConf}

          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
        '';
      };
      locations."/" = {
        proxyPass = "http://127.0.0.1:8096/";
        extraConfig = jellyfinConf;
      };
    };
  };

  system.stateVersion = "23.11";
}