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

  # The microvm framework's default host-side TimeoutSec is 150s. That's tight
  # for phantasma's first-deploy boot: fresh `mkfs` on the persist image plus
  # impermanence's bind-mount setup for 7 persisted dirs run within the same
  # window that has to reach multi-user.target. Steady-state reboots finish
  # well under 150s, but a single fresh deploy was being killed at 2:30 right
  # as fleet-tls-bootstrap was getting started. Give it more headroom.
  systemd.services."microvm@phantasma".serviceConfig.TimeoutSec = 600;
}
