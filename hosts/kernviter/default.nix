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

  # WSL2 sits behind Windows host firewall and NAT — no need for nftables,
  # and the WSL kernel lacks the nft_fib module the default ruleset requires.
  common.firewall.enable = false;

  home-manager.users.root = {
    home.stateVersion = "25.11";
    programs.git = {
      enable = true;
      settings = {
        user.name = "mutantmell";
        user.email = "malaguy@gmail.com";
        core.sshCommand = "ssh -i /etc/ssh/ssh_host_ed25519_key";
      };
    };
  };

  time.timeZone = "UTC";
  system.stateVersion = "25.11";
}
