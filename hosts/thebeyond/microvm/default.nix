{
  config,
  pkgs,
  microvm,
  ...
}: {
  common.microvm = {
    enable = true;
    guestDir = ./guests;
  };
}
