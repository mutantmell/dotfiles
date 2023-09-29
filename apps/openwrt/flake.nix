{
  description = "Apps and other software related to managing OpenWRT images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
  };

  outputs = { self, nixpkgs }: let
    allSystems = builtins.map (
      {machine, system}: "${machine}-${system}"
    ) (nixpkgs.lib.cartesianProductOfSets {
      machine = [ "x86_64" "aarch64" ];
      system = [ "linux" "darwin" ];
    });

    forAllSystems = f: nixpkgs.lib.genAttrs allSystems (system: f {
      pkgs = import nixpkgs { inherit system; };
    });
  in {
    packages = forAllSystems ({ pkgs }: {
      parse-uci = let
        python = pkgs.python311;
      in python.pkgs.buildPythonApplication {
        name = "parse-uci";
        buildInputs = with python.pkgs; [ pip ];
        src = ./parse_uci;
      };
    });

    apps = forAllSystems ({ pkgs }: {
      parse-uci = {
        type = "app";
        program = let
          path = self.packages."${pkgs.system}".parse-uci;
        in "${path}/bin/parse-uci";
      };
    });

    # TODO: use flake-utils and a common eachDefaultSystem
    devShell = forAllSystems ({ pkgs }: pkgs.mkShell {
      buildInputs = [
        pkgs.python311
      ];
    });
  };
}
