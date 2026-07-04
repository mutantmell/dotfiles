{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}: let
  hostname = "north-ambria";
  net = pkgs.mmell.lib.data.network;
  llmUser = pkgs.mmell.lib.data.users.llm;
  inherit (net.forHost hostname) host zone;
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  nix.settings.experimental-features = ["nix-command" "flakes"];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.initrd.availableKernelModules = ["xhci_pci" "nvme" "usb_storage" "usbhid" "sd_mod"];
  boot.initrd.kernelModules = ["amdgpu"];

  # Minimal label-based layout for initial install. Replace with a disko profile
  # after the actual NVMe device name and desired partitioning are known.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };
  swapDevices = [];

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.graphics = {
    enable = true;
    enable32Bit = false;
    extraPackages = [
      pkgs.rocmPackages.clr.icd
    ];
  };
  hardware.amdgpu.initrd.enable = true;

  services.fwupd.enable = true;
  services.resolved.enable = true;
  services.timesyncd.enable = true;
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  networking = {
    hostName = hostname;
    useDHCP = false;
    useNetworkd = true;
    dhcpcd.enable = false;
  };

  systemd.network = {
    enable = true;
    networks."10-app-ethernet" = {
      # Narrow once the installed machine's stable interface name or MAC is known.
      # Avoid `enx*` USB adapters so a plugged-in dongle does not also claim the
      # app-VLAN address.
      matchConfig.Name = "enp* eno* ens*";
      address = [
        host.cidr4
        host.cidr6
      ];
      gateway = [
        zone.gateway4
        zone.gateway6
      ];
      dns = [
        zone.gateway4
        zone.gateway6
      ];
      domains = ["internal"];
      networkConfig = {
        DHCP = "no";
        IPv6AcceptRA = false;
        LinkLocalAddressing = "no";
      };
    };
  };

  common.internal-pki.enable = true;
  common.openssh = {
    enable = true;
    users = ["root"];
    keys = ["deploy" "home" "edith"];
  };

  users.mutableUsers = false;
  users.groups.llm.gid = llmUser.gid;
  users.users.llm = {
    inherit (llmUser) uid;
    isSystemUser = true;
    group = "llm";
    extraGroups = ["render" "video"];
    home = "/srv/llm";
    createHome = false;
    description = "Mutable local LLM and ComfyUI workloads";
  };

  virtualisation.podman = {
    enable = true;
    dockerCompat = false;
    defaultNetwork.settings.dns_enabled = true;
  };

  systemd.tmpfiles.rules = [
    "d /srv/llm 0755 llm llm - -"
    "d /srv/llm/bin 0755 llm llm - -"
    "d /srv/llm/models 0755 llm llm - -"
    "d /srv/llm/state 0755 llm llm - -"
    "d /srv/llm/cache 0755 llm llm - -"
    "d /srv/llm/notes 0755 llm llm - -"
    "d /srv/comfyui 0755 llm llm - -"
  ];

  environment.systemPackages = with pkgs; [
    amdgpu_top
    git
    htop
    jq
    nvtopPackages.amd
    podman-compose
    # Host Python is for small diagnostics/scripts only. ComfyUI/PyTorch/ROCm
    # runtimes should stay in mutable Podman images while the stack is volatile.
    python3Minimal
    radeontop
    rocmPackages.rocm-smi
    rocmPackages.rocminfo
    tmux
    uv
    vim
    vulkan-tools
  ];

  environment.sessionVariables = {
    AMD_VULKAN_ICD = "RADV";
    HF_HOME = "/srv/llm/cache/huggingface";
    TORCH_HOME = "/srv/llm/cache/torch";
    COMFYUI_MODEL_PATH = "/srv/llm/models";
  };

  services.journald.extraConfig = ''
    SystemMaxUse=250M
    MaxFileSec=14day
  '';
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };

  home-manager.users.root = {
    home.stateVersion = "25.11";
    programs.git = {
      enable = true;
      settings = {
        user.name = "mutantmell";
        user.email = "malaguy@gmail.com";
      };
    };
  };

  system.stateVersion = "25.11";
}
