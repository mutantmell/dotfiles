{
  config,
  pkgs,
  lib,
  ...
}: {
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.mutantmell = import ../../home {
      user = "mutantmell";
      langs = ["rust"];
      is-wsl = true;
    };
  };

  wsl = {
    enable = true;
    defaultUser = "mutantmell";
  };

  networking.hostName = "kernviter";

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel"];
  };

  users.users.mutantmell = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    uid = 1000;
  };

  # SSH certificate client for connecting to homelab hosts
  common.ssh-cert-client.enable = true;

  # DNS: resolve .internal names via phantasma
  wsl.wslConf.network.generateResolvConf = false;
  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNS = ["10.97.11.2"];
      FallbackDNS = ["1.1.1.1" "8.8.8.8"];
      Domains = ["~internal" "~internal.mutantmell.net"];
    };
  };

  # WSL2 sits behind Windows host firewall and NAT — no need for nftables,
  # and the WSL kernel lacks the nft_fib module the default ruleset requires.
  networking.firewall.enable = false;

  time.timeZone = "UTC";
  system.stateVersion = "25.11";
}
