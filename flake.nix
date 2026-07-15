{
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
    # AI coding agents (claude-code, codex, …) for the locked-down dev machines.
    # Updated daily and prebuilt in cache.numtide.com — nixpkgs lags multiple
    # claude-code releases (nixpkgs 2.1.148 vs numtide 2.1.168 at wiring time).
    # NOT `follows`-ing our nixpkgs: numtide only builds/tests against their
    # pinned nixpkgs-unstable, and keeping it is what gives cache hits (their
    # packages are built against that pin). Pinned via flake.lock, so their daily
    # cadence only reaches us on a deliberate `nix flake update`.
    # ai-dev-machine-kubevirt-plan.md.
    llm-agents.url = "github:numtide/llm-agents.nix";
    retrom = {
      # NOT following our nixpkgs: fetchPnpmDeps output can drift as nixpkgs
      # moves, so Retrom packages should build against Retrom's own pinned nixpkgs.
      url = "github:JMBeresford/retrom/v0.8.4";
    };
    stevenblack-hosts = {
      url = "github:StevenBlack/hosts";
      flake = false;
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
    retrom,
    stevenblack-hosts,
    llm-agents,
  }: let
    pkgsFor = basepkgs: system:
      import basepkgs {
        inherit system;
        overlays = builtins.attrValues self.overlays;
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
    openwrtModules = import ./hosts/openwrt;
    openwrtPkgs = pkgsFor nixpkgs "x86_64-linux";
    openwrtEvaluations =
      builtins.mapAttrs
      (_: module:
        self.lib.mk-openwrt {
          pkgs = openwrtPkgs;
          modules = [module];
        })
      openwrtModules;
    openwrtDevices =
      builtins.mapAttrs
      (_: eval: eval.config.openwrt.deviceInfo)
      openwrtEvaluations;
    net = import ./lib/common/data/network.nix {inherit (nixpkgs) lib;};
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
      # Phase 1.3 — thin base VM image (KubeVirt containerDisk) for the
      # locked-down LLM dev machines. ai-dev-machine-kubevirt-plan.md. Output is
      # a streamLayeredImage script; `skopeo copy` it to creil to publish.
      dev-machine-image = import packages/dev-machine-image {
        inherit nixpkgs system;
        inherit (llm-agents.packages.${system}) claude-code codex;
        # The guest must trust creil's step-ca to clone the workspace over HTTPS
        # and to docker-pull the dev image from forgejo.internal.
        caCerts = with pkgs.mmell.lib.data.pki; [root intermediate];
      };
      # KubeVirt containerDisk for the trusted Woodpecker CI worker VM. Reuses
      # the dev-machine image substrate with role = "ci-worker".
      ci-worker-image = import packages/ci-worker-image {
        inherit nixpkgs system;
        caCerts = with pkgs.mmell.lib.data.pki; [root intermediate];
      };
      # Phase 2.2 — custom dev image (devcontainer.json pins it). Nix-built OCI
      # image carrying the dev tooling; devpod runs it as a runc container inside
      # the VM. Output is a streamLayeredImage script; `skopeo copy` it to creil.
      dev-machine-dev-image = import packages/dev-machine-dev-image {
        inherit pkgs;
        # claude-code from numtide (fresh + cached) instead of laggy nixpkgs;
        # scoped to this image only, not a global overlay override.
        inherit (llm-agents.packages.${system}) claude-code codex;
        # The agent container itself must trust creil for Forgejo API calls made
        # by tea. The base VM trust store is not enough because the devcontainer
        # has its own /etc/ssl bundle.
        caCerts = with pkgs.mmell.lib.data.pki; [root intermediate];
      };
      dev-machine = import packages/dev-machine {
        inherit pkgs;
      };
      mk-volume = import packages/mk-volume.nix {
        inherit (pkgs) writeShellScriptBin;
      };
      # v0.8.4's retrom-service package kept the old pnpm-deps hash. Keep the
      # latest release source/module, but override only the fixed-output hash.
      retrom-service = retrom.packages.${system}.retrom-service.overrideAttrs (finalAttrs: previousAttrs: {
        pnpmDeps = previousAttrs.pnpmDeps.overrideAttrs (_: {
          outputHash = "sha256-b4OG+4i+ssaaJFj0SWyzI+dHWLk5XQCiq1TVMhIo/10=";
        });
      });
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
          getopt
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
          wget
          xz
          ;
      };
      openwrt-deployer = import ./packages/openwrt-deployer {
        inherit (pkgs) lib stdenv makeWrapper openssh coreutils;
      };
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
        mmell =
          (prev.mmell or {})
          // self.packages.${prev.stdenv.hostPlatform.system}
          // {inherit stevenblack-hosts;};
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
                  overlays =
                    builtins.attrValues self.overlays
                    ++ [
                      # TODO: remove once disko stops passing aggregate module
                      # trees as vmTools.kernel. Newer nixpkgs expects the real
                      # kernel derivation there and the aggregate in
                      # vmTools.kernelModules.
                      (final: prev: {
                        vmTools =
                          prev.vmTools
                          // {
                            override = args:
                              prev.vmTools.override (
                                if
                                  args ? kernel
                                  && !(args.kernel ? target)
                                  && args.kernel ? passthru
                                  && args.kernel.passthru ? paths
                                then
                                  args
                                  // {
                                    kernel = builtins.elemAt args.kernel.passthru.paths 0;
                                    kernelModules = args.kernel;
                                  }
                                else args
                              );
                          };
                      })
                    ];
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
      mk-openwrt = args @ {
        pkgs ? pkgsFor nixpkgs "x86_64-linux",
        modules,
        ...
      }: let
        owrtData = import ./lib/common/data/openwrt.nix {inherit (nixpkgs) lib;};
      in
        nixpkgs.lib.evalModules {
          specialArgs = {
            inherit pkgs owrtData;
            openwrtLib = self.lib.openwrt;
          };
          modules =
            [
              ./hosts/openwrt/modules
            ]
            ++ modules;
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
          ./hosts/erebonia
        ];
      };

      north-ambria = self.lib.mk-nixos {
        inherit nixpkgs;
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
          home-manager.nixosModules.home-manager
          ./hosts/north-ambria
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
      pkgs = openwrtPkgs;
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
      withBuilderTarball = name: eval: let
        cfg = eval.config.openwrt;
        ibTarball = mkImageBuilderFetcher cfg.image;
      in
        (self.lib.mk-openwrt {
          inherit pkgs;
          modules = [
            openwrtModules.${name}
            {
              openwrt.image.builderTarball = ibTarball;
            }
          ];
        }).config.openwrt.build.configDir;
    in
      builtins.mapAttrs withBuilderTarball openwrtEvaluations;

    # Per-device VM manifests reuse declarative UCI/packages/keys but pin the
    # armsr/armv8 Image Builder in Nix rather than overriding build fields at
    # runtime. This keeps VM tests on the same manifest-only trust boundary.
    openwrtVmConfigurations = let
      pkgs = openwrtPkgs;
      owrtData = import ./lib/common/data/openwrt.nix {inherit (nixpkgs) lib;};
      release = owrtData.defaultRelease;
      hash = owrtData.imageBuilderHashes.${release}."armsr/armv8";
      name = "openwrt-imagebuilder-${release}-armsr-armv8.Linux-x86_64";
      tarball = pkgs.fetchurl {
        name = "${name}.tar.zst";
        url = "https://downloads.openwrt.org/releases/${release}/targets/armsr/armv8/${name}.tar.zst";
        inherit hash;
      };
      mkVmConfig = _: module:
        (self.lib.mk-openwrt {
          inherit pkgs;
          modules = [
            module
            ({lib, ...}: {
              openwrt.image = {
                target = lib.mkForce "armsr";
                subtarget = lib.mkForce "armv8";
                profile = lib.mkForce "generic";
                builderTarball = lib.mkForce tarball;
              };
            })
          ];
        }).config.openwrt.build.configDir;
    in
      builtins.mapAttrs mkVmConfig openwrtModules;

    # Apps for OpenWrt management
    apps = nixpkgs.lib.genAttrs ["x86_64-linux"] (system: let
      pkgs = pkgsFor nixpkgs system;
    in
      import ./apps {
        inherit pkgs;
        inherit openwrtDevices;
        inherit (self) openwrtConfigurations openwrtVmConfigurations;
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
          hostname = net.wireguardNetworks."wg-media".hosts.arcus.ipv4;
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
        inherit pkgs;
        inherit (pkgs) lib;
        inherit disko;
      })
      // {formatting = treefmtEval.${system}.config.build.check self;}
      // (nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        perses-dashboards =
          pkgs.runCommand "perses-dashboards-lint" {
            nativeBuildInputs = [pkgs.perses pkgs.gnutar pkgs.gzip];
          } ''
            plugins=$(mktemp -d)
            for t in ${pkgs.perses.pluginsArchive}/*.tar.gz; do
              name=$(basename "$t" .tar.gz)
              mkdir -p "$plugins/$name"
              tar -xzf "$t" -C "$plugins/$name"
            done
            percli lint -d ${./hosts/calvard/microvm/guests/tharbad/modules/dashboards} \
              --plugin.path "$plugins"
            touch $out
          '';
      })
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
