{pkgs, ...}: {
  projectRootFile = "flake.nix";
  programs.alejandra.enable = true;
  programs.prettier.enable = true;
  programs.ruff.enable = true;
  programs.shfmt.enable = true;
}
