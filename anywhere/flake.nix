{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.disko = {
    url = "github:nix-community/disko";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, ... }: {
    nixosConfigurations.vm-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./common.nix
        (import ./profiles/vm-host.nix {})
      ];
    };
    nixosConfigurations.muspelheim = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./common.nix
        ({ config, lib, pkgs, modulesPath, ... }: {
          imports = [(modulesPath + "/installer/scan/not-detected.nix")];
          boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "sd_mod" "rtsx_pci_sdmmc" ];
          boot.initrd.kernelModules = [ ];
          boot.kernelModules = [ "kvm-intel" ];
          boot.extraModulePackages = [ ];
          networking.useDHCP = lib.mkDefault true;
          nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
          hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
        })
        (import ./profiles/vm-host.nix {
          root-on-tmpfs = false;
          swap-partition = true;
          swap-size = "8G";
          zfs-reservation = "20G";
        })
      ];
    };
    nixosConfigurations.vanaheim = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./common.nix
        ({ config, lib, pkgs, modulesPath, ... }: {
          imports = [(modulesPath + "/installer/scan/not-detected.nix")];
          boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "sd_mod" "rtsx_pci_sdmmc" ];
          boot.initrd.kernelModules = [ ];
          boot.kernelModules = [ "kvm-intel" ];
          boot.extraModulePackages = [ ];
          networking.useDHCP = lib.mkDefault true;
          nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
          hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
        })
        (import ./profiles/vm-host.nix {
          disk = "/dev/nvme0n1";
          root-on-tmpfs = true;
          tmpfs-size = "4G";
          zfs-reservation = "20G";
        })
      ];
    };
  };
}
  
