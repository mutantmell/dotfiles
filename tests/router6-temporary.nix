# Temporary router6 tests — pre-deployment validation
#
# These tests validate specific host configurations before deployment.
# Remove after successful deployment to physical hardware.

{ pkgs, lib }:

{
  router6-thebeyond = import ./modules/router6-thebeyond.nix { inherit pkgs lib; };
  thebeyond-firewall-snapshot = import ./lib/thebeyond-firewall-snapshot.nix { inherit pkgs lib; };
}
