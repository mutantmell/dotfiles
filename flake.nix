{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
    nixpkgs-stable.url = github:NixOS/nixpkgs/nixos-23.11;
    nixos-hardware.url = github:NixOS/nixos-hardware/master;
    home-manager = {
      url = github:nix-community/home-manager;
      inputs.nixpkgs.follows = "nixpkgs";
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
    impermanence.url = github:nix-community/impermanence;
    attic = {
      url = github:zhaofengli/attic;
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-stable.follows = "nixpkgs-stable";
    };
  };
  outputs = {
    self, nixpkgs, nixpkgs-stable, nixos-hardware, home-manager,
      sops-nix, jovian, microvm, impermanence, attic,
  }: let
    pkgsFor = basepkgs: system: import basepkgs {
      inherit system;
      overlays = builtins.attrValues self.overlays.${system};
      config.allowUnfree = true;
    };
    allSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    forAllSystems = f: nixpkgs.lib.genAttrs allSystems (system: f {
      pkgs = pkgsFor nixpkgs system;
    });
  in {
    devShells = forAllSystems ({ pkgs }: {
      default = pkgs.mkShell {
        packages = [
          pkgs.bashInteractive
          pkgs.colmena
          pkgs.sops
        ];
      };
    });

    packages = forAllSystems ({ pkgs }: {
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

    overlays = forAllSystems ({ pkgs }: let
      extend = path: val:
        final: prev: {
          ${path} = (prev.${path} or {}) // val;
        };
    in {
      packages = extend "mmell" self.packages.${pkgs.system};
      lib = extend "mmell" {
        lib = self.lib.common // { builders = { inherit (self.lib) mk-microvm; }; };
      };
    });

    lib = {
      common = import ./lib/common { inherit (nixpkgs) lib; };
      mk-nixos = args @ { nixpkgs, system, ... }: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          {
            nixpkgs = {
              overlays = builtins.attrValues self.overlays.${system};
              config.allowUnfree = true;
            };
          }
          self.nixosModules.common
          sops-nix.nixosModules.sops
        ] ++ args.modules;
      };
      mk-colmena = host: args: {
        imports = [
          sops-nix.nixosModules.sops
          self.nixosModules.common
        ] ++ args.imports;

        deployment = {
          targetUser = "root";
          targetHost = args.host or self.lib.common.data.network.hosts.${host}.ipv4;
          tags = args.tags;
        };
      };
      mk-hive = meta: hosts: (
        builtins.mapAttrs self.lib.mk-colmena hosts
      ) // {
        inherit meta;
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
          attic.nixosModules.atticd
          self.nixosModules.common
        ];
      }];
    };

    colmena = self.lib.mk-hive {
      nixpkgs = pkgsFor nixpkgs "x86_64-linux";
      nodeNixpkgs = let
        nixpkgs-aarch = pkgsFor nixpkgs "aarch64-linux";
        nixpkgs-stable-x86_64 = pkgsFor nixpkgs-stable "x86_64-linux";
      in {
        alfheim = nixpkgs-aarch;
        nidavellir = nixpkgs-aarch;
        yggdrasil = nixpkgs-stable-x86_64;
      };
    } {
      yggdrasil = {
        imports = [
          self.nixosModules.router
          ./hosts/yggdrasil/configuration.nix
        ];
        tags = [ "mgmt" "infra" "router" ];
      };

      alfheim = {
        imports = [
          nixos-hardware.nixosModules.raspberry-pi-4
          ./hosts/alfheim/configuration.nix
        ];
        tags = [ "mgmt" "infra" "dns" ];
      };

      jotunheimr = {
        imports = [
          microvm.nixosModules.host
          ./hosts/jotunheimr/configuration.nix
        ];
        tags = [ "infra" "nas" ];
      };

      muspelheim = {
        imports = [
          microvm.nixosModules.host
          impermanence.nixosModules.impermanence
          ./hosts/muspelheim/configuration.nix
        ];
        tags = [ "host" ]; 
     };
 
     surtr = {
        imports = [
          ./hosts/muspelheim/guests/surtr/configuration.nix
        ];
        tags = [ "guest" "svc" ];
      };

      ymir = {
        imports = [
          ./hosts/muspelheim/guests/ymir/configuration.nix
        ];
        tags = [ "guest" "svc" ];
      };

      bragi = {
        imports = [
          ./hosts/vanaheim/guests/bragi/configuration.nix
        ];
        tags = [ "guest" "svc" "media" ];
      };

      njord = {
        imports = [
          ./hosts/vanaheim/guests/njord/configuration.nix
        ];
        tags = [ "guest" "svc" "git" ];
      };

      matrix = {
        imports = [
          ./cloud/matrix/configuration.nix
        ];
        tags = [ "digitalocean" "cloud" "matrix" "public" ];
      };

      nidavellir = {
        imports = [
          nixos-hardware.nixosModules.raspberry-pi-4
          ./hosts/nidavellir/configuration.nix
        ];
        host = "nidavellir.local";
        tags = [ "svc" "home" ];
      };

      thunarr = {
        imports = [
          jovian.nixosModules.jovian
          ./hosts/thunarr/configuration.nix
        ];
        tags = [ "game" "htpc" ];
      };
    };

    nixosConfigurations = {
      skadi = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          ./hosts/vanaheim/guests/skadi/configuration.nix
        ];
      };
      vanaheim = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          ./hosts/vanaheim/configuration.nix
        ];
      };
      jotunheimr = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          microvm.nixosModules.host
          ./hosts/jotunheimr/configuration.nix
        ];
      };
      muspelheim = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          impermanence.nixosModules.impermanence
          microvm.nixosModules.host
          ./hosts/muspelheim/configuration.nix
        ];
      };
      svartalfheim = self.lib.mk-nixos {
        nixpkgs = nixpkgs-stable;
        system = "x86_64-linux";
        modules = [
          ./hosts/svartalfheim/configuration.nix
        ];
      };
    };

    homeConfigurations = {
      skadi = self.lib.mk-home-config {
        inherit nixpkgs;
        system = "x86_64-linux";
        user = "mjollnir";
        langs = [ "agda" ];
      };
      svartalfheim = self.lib.mk-home-config {
        inherit nixpkgs;
        system = "x86_64-linux";
        user = "mjollnir";
        is-graphical = true;
      };
    };
  };
}
