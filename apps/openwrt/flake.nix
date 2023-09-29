{
  description = "Apps and other software related to managing OpenWRT images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs { inherit system; };
      python = pkgs.python311;
    in {
      packages = {
        parse-uci = python.pkgs.buildPythonApplication {
          name = "parse-uci";
          buildInputs = with python.pkgs; [ pip ];
          src = ./parse_uci;
        };
      };

      apps = {
        parse-uci = {
          type = "app";
          program = let
            path = self.packages.${system}.parse-uci;
          in "${path}/bin/parse-uci";
        };
      };

      devShells.default = pkgs.mkShell {
        buildInputs = [
          python
          self.packages.${system}.parse-uci
        ];
      };
    });
}
