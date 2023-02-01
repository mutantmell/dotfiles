{ config, pkgs, ...}:
{
  imports = [
    ./hardware-configuration.nix
    ./nginx.nix
    ./matrix/synapse.nix
    #./weechat.nix
    ./matrix/go-neb.nix
    ./matrix/heisenbridge.nix

    #./wireguard.nix
  ];
  
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };
  nix.settings.auto-optimise-store = true;
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    MaxFileSec=7day
  '';
 
  environment.systemPackages = with pkgs; [
    matrix-synapse
    vim
    rsync
    matrix-synapse-tools.rust-synapse-compress-state
  ];
  
  services.go-neb-bot = {
    enable = true;
    baseUrl = "https://neb.helveticastandard.com";
    databaseUrl = "go-neb.db?_busy_timeout=5000";
  };
  
  networking = {
    hostName = "matrix";
    domain = "helveticastandard.com";
  };
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  
  virtualisation.docker.enable = true;
  
  system.stateVersion = "21.11";
}
