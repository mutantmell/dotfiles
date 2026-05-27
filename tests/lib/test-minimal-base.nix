# Minimal NixOS profile for VM integration test machines.
#
# Drops documentation, locales, and unused tooling to shrink each test
# machine's closure (~200-400 MB savings per machine) and qcow2 temp
# image size during builds.
#
# Apply via `imports = [ ../lib/test-minimal-base.nix ];` in any test
# machine (router, client, attacker, upstream — anything).
{lib, ...}: {
  documentation = {
    enable = false;
    nixos.enable = false;
    man.enable = false;
    info.enable = false;
    doc.enable = false;
  };

  # Single C.UTF-8 locale — tests don't need glibc-all-locales (~110 MB)
  i18n.supportedLocales = ["C.UTF-8/UTF-8" "en_US.UTF-8/UTF-8"];

  # Don't build the channel/nix-env tooling into the test system
  nix.channel.enable = false;
}
