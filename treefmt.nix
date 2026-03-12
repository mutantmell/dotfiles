{pkgs, ...}: {
  projectRootFile = "flake.nix";
  settings.global.excludes = ["**/secrets/**"];
  programs.alejandra.enable = true;
  programs.prettier.enable = true;
  programs.ruff.enable = true;
  programs.shellcheck.enable = true;
  programs.shfmt.enable = true;
  programs.statix.enable = true;
}
