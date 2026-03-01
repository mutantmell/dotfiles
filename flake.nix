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
      url = github:microvm-nix/microvm.nix;
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
    impermanence.url = github:nix-community/impermanence;
    disko = {
      url = github:nix-community/disko;
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
      home-manager-stable, microvm-stable,
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
          pkgs.ssh-to-age
        ];
      };
    });

    packages = forAllSystems ({ system, pkgs, ... }: {
      cc = pkgs.claude-code;
      jenv = import packages/jenv.nix {
        inherit (pkgs) lib stdenv fetchFromGitHub installShellFiles;
      };
      mk-volume = import packages/mk-volume.nix {
        inherit (pkgs) writeShellScriptBin;
      };
      openwrt-builder = import ./packages/openwrt-builder {
        inherit (pkgs) lib stdenv makeWrapper python3 sops gnumake gnutar
          coreutils findutils gnugrep gawk gnused perl patch diffutils file
          unzip bzip2 which ncurses rsync xz;
      };
      installer-iso = let
        keys = builtins.fromJSON (builtins.readFile ./lib/common/data/keys.json);
        installer = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            {
              users.users.root.openssh.authorizedKeys.keys = [ keys.ssh.deploy ];
            }
          ];
        };
      in installer.config.system.build.isoImage;
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
      openwrt = import ./lib/openwrt { inherit (nixpkgs) lib; };
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

    # OpenWrt device declarations (pure data) and generated configs
    openwrtDevices = import ./hosts/openwrt { inherit (nixpkgs) lib; };

    openwrtConfigs = let
      owrtData = import ./lib/common/data/openwrt.nix { inherit (nixpkgs) lib; };
    in builtins.mapAttrs (_: device:
      self.lib.openwrt.mkDeviceConfig { inherit device owrtData; }
    ) self.openwrtDevices;

    # OpenWrt build info (JSON-serializable, for Python builder)
    openwrtBuildInfo = let
      owrtData = import ./lib/common/data/openwrt.nix { inherit (nixpkgs) lib; };
      openwrt = self.lib.openwrt;
    in builtins.mapAttrs (_: device:
      let
        config = openwrt.mkDeviceConfig { inherit device owrtData; };
        extraPackages = device.extraPackages or [];
        packages =
          if device.type == "meshAP" then openwrt.defaultMeshPackages ++ extraPackages
          else if device.type == "switch" then openwrt.defaultSwitchPackages ++ extraPackages
          else if device.type == "simpleAP" then openwrt.defaultSimpleAPPackages ++ extraPackages
          else if device.type == "router" then openwrt.defaultRouterPackages ++ extraPackages
          else throw "openwrtBuildInfo: unknown device type '${device.type}'";
      in {
        hostname = device.hostname;
        profile = device.profile;
        target = device.target;
        subtarget = device.subtarget;
        release = device.release or owrtData.defaultRelease;
        inherit packages;
        uciDefaultsScript = openwrt.uci.mkUCIDefaults {
          name = "nix-config";
          inherit config;
          preCommands = openwrt.migrationPreCommands;
        };
        secretsApplyScript = openwrt.mkSecretsApplyScript { inherit device owrtData; };
        secretsMap = openwrt.mkSecretsMap { inherit device owrtData; };
        authorizedKeys = owrtData.authorizedKeys;
        deviceType = device.type;
      }
    ) self.openwrtDevices;

    # Apps for OpenWrt management
    apps = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: let
      pkgs = pkgsFor nixpkgs system;
    in import ./apps { inherit pkgs; openwrtBuildInfo = self.openwrtBuildInfo; });

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
