{
  config,
  pkgs,
  ...
}: {
  common.microvm = {
    enable = true;
    guestDir = ./guests;
  };
}
