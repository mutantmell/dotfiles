{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
    nixpkgs-stable.url = github:NixOS/nixpkgs/nixos-23.05;
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
  };
  outputs = {
    self, nixpkgs, nixpkgs-stable, nixos-hardware, home-manager, sops-nix, jovian,
  }: let
    pkgsFor = basepkgs: system: import basepkgs {
      inherit system;
      overlays = [
        (final: prev: { jenv = self.packages.${system}.jenv;})
      ];
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
    });

    nixosModules.router = import ./modules/router.nix;

    lib = {
      mk-home-config = args @ {pkgs, ...}: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { home-conf = builtins.removeAttrs args ["pkgs"]; };
        modules = [
          ./home
        ] ++ (
          pkgs.lib.optional pkgs.stdenv.isDarwin ./home/darwin.nix
        ) ++ (
          pkgs.lib.optional pkgs.stdenv.isLinux ./home/linux.nix
        );
      };
    };

    colmena = {
      meta = {
        nixpkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        nodeNixpkgs = {
          alfheim = import nixpkgs {
            system = "aarch64-linux";
            config.allowUnfree = true;
          };
          nidavellir = import nixpkgs {
            system = "aarch64-linux";
            config.allowUnfree = true;
          };
        };
      };

      yggdrasil = {
        imports = [
          sops-nix.nixosModules.sops
          self.nixosModules.router
          ./hosts/yggdrasil/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "10.0.10.1";
          tags = [ "mgmt" "infra" "router" ];
        };
      };

      alfheim = {
        imports = [
          nixos-hardware.nixosModules.raspberry-pi-4
          sops-nix.nixosModules.sops
          ./hosts/alfheim/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "10.0.10.2";
          tags = [ "mgmt" "infra" "dns" ];
        };
      };

      jotunheimr = {
        imports = [
          sops-nix.nixosModules.sops
          ./hosts/jotunheimr/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "10.0.20.30";
          tags = [ "infra" "nas" ];
        };
      };

      surtr = {
        imports = [
          sops-nix.nixosModules.sops
          ./hosts/muspelheim/guests/surtr/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "10.0.100.40";
          tags = [ "guest" "svc" ];
        };
      };

      ymir = {
        imports = [
          sops-nix.nixosModules.sops
          ./hosts/muspelheim/guests/ymir/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "ymir.local";
          tags = [ "guest" "svc" ];
        };
      };

      bragi = {
        imports = [
          sops-nix.nixosModules.sops
          ./hosts/vanaheim/guests/bragi/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "10.0.100.50";
          tags = [ "guest" "svc" "media" ];
        };
      };

      njord = {
        imports = [
          sops-nix.nixosModules.sops
          ./hosts/vanaheim/guests/njord/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "10.0.100.51";
          tags = [ "guest" "svc" "git" ];
        };
      };

      matrix = {
        imports = [
          sops-nix.nixosModules.sops
          ./cloud/matrix/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "10.100.20.10";
          tags = [ "digitalocean" "cloud" "matrix" "public" ];
        };
      };

      nidavellir = {
        imports = [
          nixos-hardware.nixosModules.raspberry-pi-4
          sops-nix.nixosModules.sops
          ./hosts/nidavellir/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "nidavellir.local";
          tags = [ "svc" "home" ];
        };
      };

      thunarr = {
        imports = [
          jovian.nixosModules.jovian
          sops-nix.nixosModules.sops
          ./hosts/thunarr/configuration.nix
        ];
        deployment = {
          targetUser = "root";
          targetHost = "thunarr.local";
          tags = [ "game" "htpc" ];
        };
      };
    };

    nixosConfigurations.skadi = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sops-nix.nixosModules.sops
        ./hosts/vanaheim/guests/skadi/configuration.nix
      ];
    };
    nixosConfigurations.vanaheim = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sops-nix.nixosModules.sops
        ./hosts/vanaheim/configuration.nix
      ];
    };
    nixosConfigurations.muspelheim = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sops-nix.nixosModules.sops
        ./hosts/muspelheim/configuration.nix
      ];
    };
    nixosConfigurations.svartalfheim = nixpkgs-stable.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sops-nix.nixosModules.sops
        ./hosts/svartalfheim/configuration.nix
      ];
    };

    homeConfigurations = {
      skadi = self.lib.mk-home-config {
        pkgs = pkgsFor nixpkgs "x86_64-linux";
        user = "mjollnir";
        langs = [ "agda" ];
      };
      svartalfheim = self.lib.mk-home-config {
        pkgs = pkgsFor nixpkgs "x86_64-linux";
        user = "mjollnir";
        is-graphical = true;
      };
    };
  };
}
