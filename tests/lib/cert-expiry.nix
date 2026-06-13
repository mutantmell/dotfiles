{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  network = import ../../lib/common/data/network.nix {inherit lib;};
in
  pkgs.runCommand "cert-expiry" {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnused
      pkgs.jq
      pkgs.openssh
      pkgs.openssl
    ];
    allDomainsJson = builtins.toJSON network.allHostDomains;
    hostCertsDir = ../../lib/common/data/host-certs;
    x5cCertsDir = ../../lib/common/data/fleet-x5c-certs;
    keysJson = ../../lib/common/data/keys.json;
    checkScript = ../../scripts/check-cert-expiry.sh;
  } ''
    ALL_DOMAINS_JSON="$allDomainsJson" \
      HOST_CERTS_DIR="$hostCertsDir" \
      X5C_CERTS_DIR="$x5cCertsDir" \
      KEYS_JSON="$keysJson" \
      ${pkgs.bash}/bin/bash "$checkScript"

    echo PASS > "$out"
  ''
