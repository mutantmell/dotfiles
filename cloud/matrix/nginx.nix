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
      let
        matrixConfig = {
          server = { "m.server" = "${matrix-fqdn}:443"; };
          client = {
            "m.homeserver" =  { "base_url" = "https://${matrix-fqdn}"; };
            "m.identity_server" =  { "base_url" = "https://vector.im"; };
          };
        };
        # ACAO required to allow element-web on any URL to request this json file
        mkWellKnown = data: ''
          add_header Content-Type application/json;
          add_header Access-Control-Allow-Origin *;
          return 200 '${builtins.toJSON data}';
        '';
      in {
        "${fqdn}" = {
          enableACME = true;
          forceSSL = true;

          locations."= /.well-known/matrix/server".extraConfig = mkWellKnown matrixConfig.server;
          locations."= /.well-known/matrix/client".extraConfig = mkWellKnown matrixConfig.client;

          locations."/".extraConfig = ''
            return 404;
          '';

          # forward all Matrix API calls to the synapse Matrix homeserver
          locations."/_matrix".proxyPass = "http://[::1]:8008";
          locations."/_synapse".proxyPass = "http://[::1]:8008";
        };

        "${matrix-fqdn}" = {
          enableACME = true;
          forceSSL = true;

          locations."= /.well-known/matrix/server".extraConfig = mkWellKnown matrixConfig.server;
          locations."= /.well-known/matrix/client".extraConfig = mkWellKnown matrixConfig.client;

          locations."/".extraConfig = ''
            return 404;
          '';

          # forward all Matrix API calls to the synapse Matrix homeserver
          locations."/_matrix".proxyPass = "http://[::1]:8008";
          locations."/_synapse".proxyPass = "http://[::1]:8008";
        };

        "${element-fqdn}" = {
          enableACME = true;
          forceSSL = true;
          root = pkgs.element-web.override {
            conf = {
              default_server_config = matrixConfig.client;
            };
          };
        };
      };
  };

  security.acme = {
    defaults.email = "malaguy@gmail.com";
    acceptTerms = true;
  };
  
}
