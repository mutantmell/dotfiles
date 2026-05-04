{
  nixConfig = {
    extra-substituters = ["https://retrom.cachix.org"];
    extra-trusted-public-keys = ["retrom.cachix.org-1:6fjezFeBSDzHkUvpyLMe58wfi99V4RO8M5Iod4sMxFE="];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager-stable = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jovian = {
      url = "github:Jovian-Experiments/Jovian-NixOS";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    microvm-stable = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix.url = "github:numtide/treefmt-nix";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    retrom = {
      url = "github:JMBeresford/retrom";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {
    self,
    nixpkgs,
    nixpkgs-stable,
    nixos-hardware,
    home-manager,
    sops-nix,
    jovian,
    microvm,
    impermanence,
    disko,
    home-manager-stable,
    microvm-stable,
    nixos-wsl,
    deploy-rs,
    treefmt-nix,
    rust-overlay,
    retrom,
  }: let
    pkgsFor = basepkgs: system:
      import basepkgs {
        inherit system;
        overlays =
          builtins.attrValues self.overlays
          ++ [
            (import rust-overlay)
          ];
        config.allowUnfree = true;
      };
    allSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f:
      nixpkgs.lib.genAttrs allSystems (system:
        f {
          inherit system;
          pkgs = pkgsFor nixpkgs system;
        });
    treefmtEval = forAllSystems (sys: treefmt-nix.lib.evalModule sys.pkgs ./treefmt.nix);
    openwrtDevices = import ./hosts/openwrt {inherit (nixpkgs) lib;};
  in {
    devShells = forAllSystems ({
      system,
      pkgs,
    }: {
      default = pkgs.mkShell {
        packages = [
          pkgs.bashInteractive
          #          pkgs.sops
          #          pkgs.ssh-to-age
          pkgs.jq
          pkgs.skopeo
          pkgs.openssl
          pkgs.pkg-config
          pkgs.rust-bin.stable.latest.default
        ];
      };
    });
    formatter = forAllSystems (sys: treefmtEval.${sys.pkgs.stdenv.hostPlatform.system}.config.build.wrapper);

    packages = forAllSystems ({
      system,
      pkgs,
      ...
    }: {
      jenv = import packages/jenv.nix {
        inherit (pkgs) lib stdenv fetchFromGitHub installShellFiles;
      };
      mk-volume = import packages/mk-volume.nix {
        inherit (pkgs) writeShellScriptBin;
      };
      openwrt-builder = import ./packages/openwrt-builder {
        inherit
          (pkgs)
          lib
          stdenv
          makeWrapper
          python3
          sops
          gnumake
          gnutar
          coreutils
          findutils
          gnugrep
          gawk
          gnused
          perl
          patch
          diffutils
          file
          unzip
          bzip2
          which
          ncurses
          rsync
          xz
          ;
      };
      deployd-helper = import packages/deployd-helper {
        inherit (pkgs) lib rustPlatform;
      };
      deployd-api = import packages/deployd-api {
        inherit (pkgs) lib rustPlatform;
      };
      openwrt-deployer = import ./packages/openwrt-deployer {
        inherit (pkgs) lib stdenv makeWrapper openssh coreutils;
      };
      cc-sandbox = import packages/cc-sandbox {
        inherit (pkgs) lib stdenv makeWrapper python3 skopeo nix cacert;
      };
      claude-sandbox-image = import packages/claude-sandbox-image {inherit pkgs;};
      installer-iso = let
        keys = builtins.fromJSON (builtins.readFile ./lib/common/data/keys.json);
        installer = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            {
              users.users.root.openssh.authorizedKeys.keys = [keys.ssh.deploy];
            }
          ];
        };
      in
        installer.config.system.build.isoImage;
    });

    nixosModules = let
      importModule = dir: value:
        if value == "directory"
        then import (./modules + "/${dir}")
        else abort "invalid entry in modules";
    in
      builtins.mapAttrs importModule (builtins.readDir ./modules);

    overlays = {
      packages = final: prev: {
        mmell = (prev.mmell or {}) // self.packages.${prev.stdenv.hostPlatform.system};
      };

      lib = final: prev: {
        mmell =
          (prev.mmell or {})
          // {
            lib =
              self.lib.common
              // {
                builders = {inherit (self.lib) mk-microvm mk-incus-vm mk-incus-container;};
                inherit (self.lib) diskoProfiles;
              };
          };
      };
    };

    lib = {
      common = import ./lib/common {inherit (nixpkgs) lib;};
      openwrt = import ./lib/openwrt {inherit (nixpkgs) lib;};
      diskoProfiles = {
        tmpfs = import ./profiles/disko/tmpfs.nix;
        btrfs = import ./profiles/disko/btrfs.nix;
        incus-vm = import ./profiles/disko/incus-vm.nix;
      };
      commonModules = [
        sops-nix.nixosModules.sops
        impermanence.nixosModules.impermanence
        self.nixosModules.common
        self.nixosModules."promtail-client"
        self.nixosModules."node-exporter-client"
        self.nixosModules."fluent-bit-agent"
        retrom.nixosModules.retrom
      ];
      mk-nixos = args @ {
        nixpkgs,
        system,
        ...
      }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit self;
            inputs = {inherit nixpkgs nixpkgs-stable sops-nix microvm disko deploy-rs;};
          };
          modules =
            [
              {
                nixpkgs = {
                  overlays = builtins.attrValues self.overlays;
                  config.allowUnfree = true;
                };
              }
            ]
            ++ self.lib.commonModules
            ++ args.modules;
        };

      mk-microvm = args:
        nixpkgs.lib.mkMerge [
          args
          {
            imports = self.lib.commonModules;
          }
        ];
      mk-incus-vm = guestModule:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules =
            [
              guestModule
              disko.nixosModules.disko
              ./modules/incus/guest-options.nix
              ./modules/incus/disko-virtual-machine.nix
              {
                nixpkgs = {
                  overlays = builtins.attrValues self.overlays;
                  config.allowUnfree = true;
                };
              }
            ]
            ++ self.lib.commonModules;
        };
      mk-incus-container = guestModule:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules =
            [
              guestModule
              ./modules/incus/guest-options.nix
              "${nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"
              {
                nixpkgs = {
                  overlays = builtins.attrValues self.overlays;
                  config.allowUnfree = true;
                };
              }
            ]
            ++ self.lib.commonModules;
        };
    };

    nixosConfigurations = {
      thebeyond = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          self.nixosModules.router6
          microvm.nixosModules.host
          ./hosts/thebeyond
        ];
      };

      calvard = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          self.nixosModules.router6
          microvm.nixosModules.host
          home-manager.nixosModules.home-manager
          self.nixosModules.incus
          ./hosts/calvard
        ];
      };
      liberl = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          microvm.nixosModules.host
          home-manager.nixosModules.home-manager
          ./hosts/liberl
        ];
      };
      erebonia = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          microvm.nixosModules.host
          home-manager.nixosModules.home-manager
          self.nixosModules.incus
          self.nixosModules.deployd
          ./hosts/erebonia
        ];
      };

      kernviter = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          nixos-wsl.nixosModules.default
          home-manager.nixosModules.home-manager
          ./hosts/kernviter
        ];
      };

      angbar = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          nixos-hardware.nixosModules.lenovo-thinkpad-x1-7th-gen
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          ./hosts/angbar
        ];
      };

      arcus = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          jovian.nixosModules.jovian
          ./hosts/arcus
        ];
      };
    };

    homeConfigurations = {
      # Standalone home-manager profiles, keyed by user@hostname.
      # Resolved automatically by: home-manager switch --flake .
      "mutantmell@edith" = home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsFor nixpkgs "x86_64-linux";
        modules = [
          sops-nix.homeManagerModules.sops
          (import ./home {
            user = "mutantmell";
            langs = ["agda" "rust"];
            extraModules = [
              ./home/hosts/edith.nix
            ];
          })
        ];
      };
      "mutantmell@angbar" = home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsFor nixpkgs "x86_64-linux";
        modules = [
          (import ./home {
            user = "mutantmell";
            langs = ["agda" "rust"];
            is-graphical = true;
          })
        ];
      };
    };

    # Per-device config build artifacts (derivations bundling all config files)
    # Text-only outputs — system choice doesn't affect content
    openwrtConfigurations = let
      pkgs = pkgsFor nixpkgs "x86_64-linux";
      owrtData = import ./lib/common/data/openwrt.nix {inherit (nixpkgs) lib;};

      # Returns a pkgs.fetchurl derivation for the Image Builder tarball for the
      # given device, or null if the hash isn't registered yet.
      mkImageBuilderFetcher = device: let
        release = device.release or owrtData.defaultRelease;
        targetKey = "${device.target}/${device.subtarget}";
        hashes = owrtData.imageBuilderHashes.${release} or {};
        hash = hashes.${targetKey} or null;
        ibName = "openwrt-imagebuilder-${release}-${device.target}-${device.subtarget}.Linux-x86_64";
      in
        if hash == null || hash == ""
        then null
        else
          pkgs.fetchurl {
            name = "${ibName}.tar.zst";
            url = "https://downloads.openwrt.org/releases/${release}/targets/${device.target}/${device.subtarget}/${ibName}.tar.zst";
            inherit hash;
          };
    in
      builtins.mapAttrs (
        _: device: let
          files = self.lib.openwrt.mkConfigFiles {inherit device owrtData;};
          ibTarball = mkImageBuilderFetcher device;
          release = device.release or owrtData.defaultRelease;
        in
          pkgs.runCommand "openwrt-config-${device.hostname}" {} ''
            mkdir -p $out
            cat > $out/build.json <<'EOF'
            ${builtins.toJSON ({
                inherit (device) hostname;
                inherit (device) profile;
                inherit (device) target;
                inherit (device) subtarget;
                inherit release;
                deviceType = device.type;
                packages = self.lib.openwrt.packagesForDevice device;
                secretsMap = self.lib.openwrt.mkSecretsMap {inherit device owrtData;};
                uciDefaults = "${files.uciFile}";
                authorizedKeys = "${files.keysFile}";
              }
              // nixpkgs.lib.optionalAttrs (ibTarball != null) {
                imageBuilderTarball = "${ibTarball}";
              })}
            EOF
          ''
      )
      openwrtDevices;

    # Apps for OpenWrt management
    apps = nixpkgs.lib.genAttrs ["x86_64-linux"] (system: let
      pkgs = pkgsFor nixpkgs system;
    in
      import ./apps {
        inherit pkgs;
        inherit openwrtDevices;
        inherit (self) openwrtConfigurations;
      });

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

        arcus = {
          hostname = "10.100.20.10"; # WG tunnel IP
          profiles.system = {
            sshUser = "root";
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.arcus;
            magicRollback = true;
            autoRollback = true;
          };
        };
      };
    };

    checks = forAllSystems ({
      system,
      pkgs,
    }:
      (import ./tests {
        inherit pkgs disko;
        inherit (pkgs) lib;
      })
      // (nixpkgs.lib.optionalAttrs (deploy-rs.lib ? ${system})
        (deploy-rs.lib.${system}.deployChecks self.deploy))
      // {formatting = treefmtEval.${system}.config.build.check self;}
      # Host config eval checks — catch broken configs before deploy
      // (let
        mkHostCheck = name: let
          # Force full evaluation of the NixOS toplevel derivation.
          # builtins.seq evaluates the first arg (forcing any eval errors)
          # but doesn't add it as a build dependency of the runCommand.
          inherit (self.nixosConfigurations.${name}.config.system.build) toplevel;
        in
          builtins.seq toplevel.drvPath
          (pkgs.runCommand "host-eval-${name}" {} ''
            echo "Host ${name} config evaluated successfully"
            echo ok > $out
          '');
      in
        nixpkgs.lib.mapAttrs' (name: _: nixpkgs.lib.nameValuePair "host-eval-${name}" (mkHostCheck name))
        self.nixosConfigurations));
  };
}
