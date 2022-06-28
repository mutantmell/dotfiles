{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };
  outputs = { nixpkgs, nixos-hardware, ... }: {
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
      };

      alfheim = { config, pkgs, lib, ... }: (import ./hosts/alfheim/configuration.nix { inherit config pkgs lib nixos-hardware; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "10.0.10.2";
          tags = [ "mgmt" "infra" "dns" ];
        };
        nixpkgs.system = "aarch64-linux";
      };

      bragi = { config, pkgs, lib, ... }: (import ./hosts/vanaheim/guests/bragi/configuration.nix { inherit config pkgs lib; }) // {
        deployment = {
          targetUser = "root";
          targetHost = "bragi.local";
          tags = [ "guest" "media" ];
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
    };
  };
}
