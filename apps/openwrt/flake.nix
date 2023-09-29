{
  description = "Python example flake for Zero to Nix";

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
  };
}
