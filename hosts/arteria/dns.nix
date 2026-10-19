{pkgs, ...}: let
  net = pkgs.mmell.lib.data.network;
in {
  # router6's kresd retains the existing client-facing port 53 listeners and
  # firewall policy. Its only upstream is this private backend, which owns the
  # same local records as phantasma and needs no mesh/upstream link to serve them.
  services.unbound = {
    enable = true;
    resolveLocalQueries = false;
    enableRootTrustAnchor = false;
    settings = {
      server = {
        interface = ["127.0.0.1"];
        port = 5353;
        access-control = ["127.0.0.0/8 allow"];
        # The existing upstream validates Internet DNSSEC. These local zones
        # are unsigned; avoid a second validation layer or network trust-anchor
        # bootstrap here, matching router6's STUB policy on arteria.
        module-config = "iterator";
        inherit (pkgs.mmell.lib.data.dns) local-zone local-data;
      };
      forward-zone = [
        {
          name = ".";
          forward-addr = [net.networks.transit.gateway4];
          # Never fall back to independent Internet recursion on an upstream
          # outage. No internal-zone forwarding is configured in either copy.
          forward-first = false;
        }
      ];
    };
  };
}
