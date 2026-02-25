{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
    nixpkgs-stable.url = github:NixOS/nixpkgs/nixos-24.11;
    nixos-hardware.url = github:NixOS/nixos-hardware/master;
    home-manager = {
      url = github:nix-community/home-manager;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager-stable = {
      url = github:nix-community/home-manager/release-24.11;
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
    sops-nix = {
      url = github:Mic92/sops-nix;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jovian = {
      url = github:Jovian-Experiments/Jovian-NixOS;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    microvm = {
      url = github:astro/microvm.nix;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    microvm-stable = {
      url = github:astro/microvm.nix;
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
    impermanence.url = github:nix-community/impermanence;
    disko = {
      url = github:nix-community/disko;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    openwrt-imagebuilder = {
      url = github:astro/nix-openwrt-imagebuilder;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = github:serokell/deploy-rs;
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {
    self, nixpkgs, nixpkgs-stable, nixos-hardware, home-manager,
      sops-nix, jovian, microvm, impermanence, disko,
      home-manager-stable, microvm-stable, openwrt-imagebuilder,
      deploy-rs,
  }: let
    pkgsFor = basepkgs: system: import basepkgs {
      inherit system;
      overlays = builtins.attrValues self.overlays;
      config.allowUnfree = true;
    };
    allSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    forAllSystems = f: nixpkgs.lib.genAttrs allSystems (system: f {
      inherit system;
      pkgs = pkgsFor nixpkgs system;
    });
  in {
    devShells = forAllSystems ({ system, pkgs }: {
      default = pkgs.mkShell {
        packages = [
          pkgs.bashInteractive
          pkgs.sops
        ];
      };
    });

    packages = forAllSystems ({ pkgs, ... }: {
      cc = pkgs.claude-code;
      jenv = import packages/jenv.nix {
        inherit (pkgs) lib stdenv fetchFromGitHub installShellFiles;
      };
      mk-volume = import packages/mk-volume.nix {
        inherit (pkgs) writeShellScriptBin;
      };
    });

    nixosModules = let
      importModule = dir: value:
        if value == "directory"
        then import (./modules + "/${dir}")
        else abort "invalid entry in modules";
    in builtins.mapAttrs importModule (builtins.readDir ./modules);

    overlays = {
      packages = final: prev: {
        mmell = (prev.mmell or {}) // self.packages.${prev.stdenv.hostPlatform.system};
      };
      lib = final: prev: {
        mmell = (prev.mmell or {}) // {
          lib = self.lib.common // {
            builders = { inherit (self.lib) mk-microvm; };
            inherit (self.lib) diskoProfiles;
          };
        };
      };
    };

    lib = {
      common = import ./lib/common { inherit (nixpkgs) lib; };
      openwrt = import ./lib/openwrt { inherit (nixpkgs) lib; inherit openwrt-imagebuilder; };
      diskoProfiles = {
        router = import ./profiles/disko/router.nix;
        vm-host = import ./profiles/disko/vm-host.nix;
      };
      mk-nixos = args @ { nixpkgs, system, ... }: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit self;
          inputs = { inherit nixpkgs nixpkgs-stable sops-nix microvm disko deploy-rs; };
        };
        modules = [
          {
            nixpkgs = {
              overlays = builtins.attrValues self.overlays;
              config.allowUnfree = true;
            };
          }
          self.nixosModules.common
          self.nixosModules."promtail-client"
          sops-nix.nixosModules.sops
        ] ++ args.modules;
      };
      mk-home-config = args @ { nixpkgs, system, ... }: let
        pkgs = pkgsFor nixpkgs system;
      in home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { home-conf = builtins.removeAttrs args ["nixpkgs" "system"]; };
        modules = [
          ./home
        ] ++ (
          pkgs.lib.optional pkgs.stdenv.isDarwin ./home/darwin.nix
        ) ++ (
          pkgs.lib.optional pkgs.stdenv.isLinux ./home/linux.nix
        );
      };
      mk-microvm = args: nixpkgs.lib.mkMerge [ args {
        imports = [
          sops-nix.nixosModules.sops
          impermanence.nixosModules.impermanence
          self.nixosModules.common
          self.nixosModules."promtail-client"
        ];
      }];
    };

    nixosConfigurations = {
      thebeyond = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          self.nixosModules.router6
          microvm-stable.nixosModules.host
          home-manager.nixosModules.home-manager
          impermanence.nixosModules.impermanence
          ./hosts/thebeyond
        ];
      };

      calvard = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          self.nixosModules.router6
          microvm.nixosModules.host
          home-manager.nixosModules.home-manager
          impermanence.nixosModules.impermanence
          ./hosts/calvard
        ];
      };
      remiferia = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          microvm.nixosModules.host
          home-manager.nixosModules.home-manager
          ./hosts/remiferia
        ];
      };
      erebonia = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          impermanence.nixosModules.impermanence
          microvm.nixosModules.host
          home-manager.nixosModules.home-manager
          self.nixosModules.incus
          ./hosts/erebonia
        ];
      };
#      azoth = self.lib.mk-nixos {
#        inherit nixpkgs;
#        system = "aarch64-linux";
#        modules = [
#          home-manager.nixosModules.home-manager
#          nixos-hardware.nixosModules.raspberry-pi-4
#          ./hosts/azoth
#        ];
#      };
#      arcus = self.lib.mk-nixos {
#        inherit nixpkgs;
#        system = "x86_64-linux";
#        modules = [
#          home-manager.nixosModules.home-manager
#          jovian.nixosModules.jovian
#          ./hosts/arcus
#        ];
#      };
    };

    homeConfigurations = {
      mjollnir = self.lib.mk-home-config {
        inherit nixpkgs;
        system = "x86_64-linux";
        user = "mjollnir";
        langs = [ "agda" "rust" ];
      };
    };

    # OpenWrt images (x86_64-linux only - imagebuilder limitation)
    openwrtImages = let
      pkgs = pkgsFor nixpkgs "x86_64-linux";
      openwrt = self.lib.openwrt;
      devices = import ./hosts/openwrt { inherit (nixpkgs) lib; inherit pkgs openwrt; };
    in devices;

    # Apps for OpenWrt management
    apps = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: let
      pkgs = pkgsFor nixpkgs system;
    in import ./apps { inherit pkgs; });

    # deploy-rs deployment configurations
    deploy = {
      sshUser = "root";
      user = "root";

      nodes = {
        thebeyond = {
          hostname = "thebeyond.internal";
          profiles.system = {
            sshUser = "root";
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.thebeyond;

            # Test activation before making it boot default
            # This allows rollback if something goes wrong
            magicRollback = true;
            autoRollback = true;
          };
        };
      };
    };

    # Merge NixOS tests and deploy-rs checks
    checks = nixpkgs.lib.recursiveUpdate
      (nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: let
        pkgs = pkgsFor nixpkgs system;
      in import ./tests { inherit pkgs; lib = pkgs.lib; }))
      (builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib);
  };
}
