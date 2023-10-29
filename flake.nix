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
    flake-utils.url = github:numtide/flake-utils;
    jovian = {
      url = github:Jovian-Experiments/Jovian-NixOS;
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {
    self, nixpkgs, nixpkgs-stable, nixos-hardware, home-manager, sops-nix, flake-utils, jovian,
  }: (flake-utils.lib.eachDefaultSystem (system: let
    pkgs = import nixpkgs { inherit system; };
  in {
    devShells.default = pkgs.mkShell {
      packages = [
        pkgs.bashInteractive
        pkgs.colmena
        pkgs.sops
      ];
    };

    packages = {
      jenv = import packages/jenv.nix {
        inherit (pkgs) lib stdenv fetchFromGitHub installShellFiles;
      };
    };

    nixosModules.router = import ./modules/router.nix;

    templates = {
      mk-home-config = args: home-manager.lib.homeManagerConfiguration (rec {
        inherit pkgs;
        extraSpecialArgs = { home-conf = args; };
        modules = [
          ./home
        ] ++ (
          pkgs.lib.optional pkgs.stdenv.isDarwin ./home/darwin.nix
        ) ++ (
          pkgs.lib.optional pkgs.stdenv.isLinux ./home/linux.nix
        );
      });
    };
  })) // {
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

      yggdrasil = { config, pkgs, lib, ... }: (import ./hosts/yggdrasil/configuration.nix { inherit config pkgs lib sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.0.10.1";
          tags = [ "mgmt" "infra" "router" ];
        };
      };

      alfheim = { config, pkgs, lib, ... }: (import ./hosts/alfheim/configuration.nix { inherit config pkgs lib nixos-hardware sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.0.10.2";
          tags = [ "mgmt" "infra" "dns" ];
        };
      };

      jotunheimr = { config, pkgs, lib, ... }: (import ./hosts/jotunheimr/configuration.nix { inherit config pkgs lib nixos-hardware; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.0.20.30";
          tags = [ "infra" "nas" ];
        };
      };

      surtr = { config, pkgs, lib, ... }: (import ./hosts/muspelheim/guests/surtr/configuration.nix { inherit config pkgs lib sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.0.100.40";
          tags = [ "guest" "svc" ];
        };
      };

      ymir = { config, pkgs, lib, ... }: (import ./hosts/muspelheim/guests/ymir/configuration.nix { inherit config pkgs lib sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "ymir.local";
          tags = [ "guest" "svc" ];
        };
      };

      bragi = { config, pkgs, lib, ... }: (import ./hosts/vanaheim/guests/bragi/configuration.nix { inherit config pkgs lib sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.0.100.50";
          tags = [ "guest" "svc" "media" ];
        };
      };

      njord = { config, pkgs, lib, ... }: (import ./hosts/vanaheim/guests/njord/configuration.nix { inherit config pkgs lib sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.0.100.51";
          tags = [ "guest" "svc" "git" ];
        };
      };

      matrix = { config, pkgs, lib, ... }: (import ./cloud/matrix/configuration.nix { inherit config pkgs lib sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.100.20.10";
          tags = [ "digitalocean" "cloud" "matrix" "public" ];
        };
      };

      nidavellir = { config, pkgs, lib, ... }: (import ./hosts/nidavellir/configuration.nix { inherit config pkgs lib nixos-hardware sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "nidavellir.local";
          tags = [ "svc" "home" ];
        };
      };

      thunarr = { config, pkgs, lib, ... }: (import ./hosts/nidavellir/configuration.nix { inherit config pkgs lib jovian sops-nix; }) // {
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
        ./hosts/vanaheim/guests/skadi/configuration.nix
        sops-nix.nixosModules.sops
      ];
    };
    nixosConfigurations.vanaheim = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/vanaheim/configuration.nix
        sops-nix.nixosModules.sops
      ];
    };
    nixosConfigurations.muspelheim = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/muspelheim/configuration.nix
        sops-nix.nixosModules.sops
      ];
    };
    nixosConfigurations.svartalfheim = nixpkgs-stable.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/svartalfheim/configuration.nix
        sops-nix.nixosModules.sops
      ];
    };

    homeConfigurations = {
      skadi = self.templates."x86_64-linux".mk-home-config {
        user = "mjollnir";
        langs = [ "agda" ];
      };
      svartalfheim = self.templates."x86_64-linux".mk-home-config {
        user = "mjollnir";
        is-graphical = true;
      };
    };
  };
}
