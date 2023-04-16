{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
    nixpkgs-stable.url = github:NixOS/nixpkgs/nixos-22.11;
    nixos-hardware.url = github:NixOS/nixos-hardware/master;
    home-manager = {
      url = github:nix-community/home-manager;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = github:Mic92/sops-nix;
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, nixpkgs-stable, nixos-hardware, home-manager, sops-nix }: {
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
        #nixpkgs.system = "aarch64-linux";
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

    homeConfigurations = let
      system = "x86_64-linux";
      username = "mjollnir";
      pkgs = nixpkgs.legacyPackages.${system};
      confFor = {
        linux = ./users/linux.nix;
      };
      mkHomeConfig = {
        os ? "linux",
        extra-modules ? []
      }: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./users/home.nix
          (builtins.getAttr os confFor)
        ] ++ extra-modules;
      };
    in {
      skadi = mkHomeConfig {};
      svartalfheim = mkHomeConfig { extra-modules = [ ./users/graphical.nix ]; };
    };
  };
}
