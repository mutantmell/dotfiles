{ config, pkgs, lib, ... }:

let
  join = hostName: domain: hostName + (
    lib.strings.optionalString (domain != null) ".${domain}"
  );
  fqdn = config.networking.domain;
  matrix-fqdn = join "matrix" config.networking.domain;
  riot-fqdn = join "riot" config.networking.domain;
  element-fqdn = join "elem" config.networking.domain;
  weechat-fqdn = join "weechat" config.networking.domain;
  neb-fqdn = join "neb" config.networking.domain;
in
{
  services.nginx = {
    enable = true;
    # only recommendedProxySettings and recommendedGzipSettings are strictly required,
    # but the rest make sense as well
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;

    appendHttpConfig = ''
      limit_req_zone $binary_remote_addr zone=weechat:10m rate=5r/m;  # Setup brute force protection

      error_log stderr;
      access_log syslog:server=unix:/dev/log combined;
    '';

    virtualHosts =
      let wellKnown = {
        server = let
          # use 443 instead of the default 8448 port to unite
          # the client-server and server-server port for simplicity
          json = { "m.server" = "${matrix-fqdn}:443"; };
        in ''
          add_header Content-Type application/json;
          return 200 '${builtins.toJSON json}';
        '';
        client = let
          json = {
            "m.homeserver" =  { "base_url" = "https://${matrix-fqdn}"; };
            "m.identity_server" =  { "base_url" = "https://vector.im"; };
          };
          # ACAO required to allow element-web on any URL to request this json file
        in ''
          add_header Content-Type application/json;
          add_header Access-Control-Allow-Origin *;
          return 200 '${builtins.toJSON json}';
        '';
      };
    in {
      # This host section can be placed on a different host than the rest,
      # i.e. to delegate from the host being accessible as ${config.networking.domain}
      # to another host actually running the Matrix homeserver.
      "${fqdn}" = {
        enableACME = true;
        forceSSL = true;

        locations."= /.well-known/matrix/server".extraConfig = wellKnown.server;
        locations."= /.well-known/matrix/client".extraConfig = wellKnown.client;
          
        locations."/".extraConfig = ''
          return 404;
        '';

        # forward all Matrix API calls to the synapse Matrix homeserver
        locations."/_matrix" = {
          proxyPass = "http://[::1]:8008"; # without a trailing /
        };
      };

      # Reverse proxy for Matrix client-server and server-server communication
      ${matrix-fqdn} = {
        enableACME = true;
        forceSSL = true;

        locations."= /.well-known/matrix/server".extraConfig = wellKnown.server;
        locations."= /.well-known/matrix/client".extraConfig = wellKnown.client;
        
        # Or do a redirect instead of the 404, or whatever is appropriate for you.
        # But do not put a Matrix Web client here! See the Element Web section below.
        locations."/".extraConfig = ''
          return 404;
        '';

        # forward all Matrix API calls to the synapse Matrix homeserver
        locations."/_matrix" = {
          proxyPass = "http://[::1]:8008"; # without a trailing /
        };
      };

      "${element-fqdn}" = {
        enableACME = true;
        forceSSL = true;
        root = pkgs.element-web;
      };

      "${riot-fqdn}" = {
        enableACME = true;
        forceSSL = true;
        globalRedirect="${element-fqdn}";
      };

      "${weechat-fqdn}" = {
        enableACME = true;
        forceSSL = true;
        locations."/weechat" = {
          proxyPass = "http://localhost:9001/weechat";
          proxyWebsockets = true;
          # extraConfig from https://github.com/garbas/dotfiles/blob/master/nixos/floki.nix
          extraConfig = ''
            proxy_read_timeout 604800;                # Prevent idle disconnects
            proxy_set_header X-Real-IP $remote_addr;  # Let Weechat see client's IP
            limit_req zone=weechat burst=1 nodelay;   # Brute force prevention
          '';
        };
      };

      "${neb-fqdn}" = {
        enableACME = true;
        forceSSL = true;
        locations."/admin".extraConfig = ''
          return 404;
        '';
        locations."/" = {
          proxyPass = "http://localhost:4050";
        };
      };
      
    };
  };

  security.acme = {
    defaults.email = "malaguy@gmail.com";
    acceptTerms = true;
  };
  
}
