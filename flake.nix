{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
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
  outputs = { self, nixpkgs, nixos-hardware, home-manager, sops-nix }: {
    colmena = {
      meta = {
        nixpkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
      };

      yggdrasil = { config, pkgs, lib, ... }: (import ./hosts/yggdrasil/configuration.nix { inherit config pkgs lib nixos-hardware; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.0.10.1";
          tags = [ "mgmt" "infra" "router" ];
        };

        deployment.keys = {
          "chap-secrets" = {
            keyCommand = [ "age" "--decrypt" "-i" "secrets/deploy" "hosts/yggdrasil/secure/chap-secrets.age" ];
            destDir = "/etc/ppp";
            user = "root";
            group = "root";
            permissions = "0400";
          };
        };
      };

      alfheim = { config, pkgs, lib, ... }: (import ./hosts/alfheim/configuration.nix { inherit config pkgs lib nixos-hardware; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.0.10.2";
          tags = [ "mgmt" "infra" "dns" ];
        };
        nixpkgs.system = "aarch64-linux";

        deployment.keys = {
          "intermediate_ca.key" = {
            keyCommand = [ "age" "--decrypt" "-i" "secrets/deploy" "hosts/alfheim/secure/intermediate_ca.key.age" ];
            destDir = "/etc/step-ca/data";
            user = "step-ca";
            group = "step-ca";
            permissions = "0400";
          };
          "intermediate-password-file" = {
            keyCommand = [ "age" "--decrypt" "-i" "secrets/deploy" "hosts/alfheim/secure/intermediate-password-file.age" ];
            destDir = "/etc/step-ca/data";
            user = "step-ca";
            group = "step-ca";
            permissions = "0400";
          };
          # this causes errors -- the keycloak user doesn't seem to want to exist when this is sent?
          "keycloak_password_file" = {
            keyCommand = [ "age" "--decrypt" "-i" "secrets/deploy" "hosts/alfheim/secure/keycloak_password_file.age" ];
            destDir = "/etc/keycloak/data";
            user = "keycloak";
            group = "keycloak";
            permissions = "0400";
          };
        };
      };

      jotunheimr = { config, pkgs, lib, ... }: (import ./hosts/jotunheimr/configuration.nix { inherit config pkgs lib nixos-hardware; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "jotunheimr.local";
          tags = [ "infra" "nas" ];
        };
      };

      bragi = { config, pkgs, lib, ... }: (import ./hosts/vanaheim/guests/bragi/configuration.nix { inherit config pkgs lib; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "bragi.local";
          tags = [ "guest" "svc" "media" ];
        };

        deployment.keys = {
          "bragi.crt" = {
            keyCommand = [ "age" "--decrypt" "-i" "secrets/deploy" "hosts/vanaheim/guests/bragi/secure/bragi.crt.age" ];
            destDir = "/etc";
            user = "nginx";
            group = "nginx";
            permissions = "0400";
          };
          "bragi.key" = {
            keyCommand = [ "age" "--decrypt" "-i" "secrets/deploy" "hosts/vanaheim/guests/bragi/secure/bragi.key.age" ];
            destDir = "/etc";
            user = "nginx";
            group = "nginx";
            permissions = "0400";
          };
          "jellyfin-smb" = {
            keyCommand = [ "age" "--decrypt" "-i" "secrets/deploy" "hosts/vanaheim/guests/bragi/secure/credentials.age" ];
            destDir = "/etc";
            user = "root";
            group = "wheel";
            permissions = "0400";
          };
        };
      };

      njord = { config, pkgs, lib, ... }: (import ./hosts/vanaheim/guests/njord/configuration.nix { inherit config pkgs lib sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "njord.local";
          tags = [ "guest" "svc" "git" ];
        };

        deployment.keys = {
          "credentials" = {
            keyCommand = [ "age" "--decrypt" "-i" "secrets/deploy" "hosts/vanaheim/guests/njord/secure/credentials.age" ];
            destDir = "/etc/nas/";
            user = "root";
            group = "wheel";
            permissions = "0400";
          };
        };
      };

      matrix = { config, pkgs, lib, ... }: (import ./cloud/matrix/configuration.nix { inherit config pkgs lib sops-nix; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "helveticastandard.com";
          tags = [ "digitalocean" "cloud" "matrix" "public" ];
        };
      };
    };

    homeConfigurations = let
      system = "x86_64-linux";
      username = "mjollnir";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      "${username}" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        
        modules = [
          ./users/home.nix
        ];
      };
    };

  };
}
