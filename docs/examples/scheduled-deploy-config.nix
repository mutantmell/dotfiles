# Example: Automated scheduled deployment via wrapper flakes and deploy-rs
#
# Each deployment target has a wrapper flake in its own git repo. The module
# clones these repos, updates their inputs on a schedule, and deploys via
# deploy-rs with automatic rollback.
#
# Prerequisites:
#   1. Create a git repo with a wrapper flake.nix for each target
#   2. Ensure the VM host has SSH access to the repo and the target
{...}: {
  imports = [../modules/scheduled-deploy];

  services.scheduled-deploy = {
    enable = true;

    # Where local checkouts are stored (default shown)
    # stateDirectory = "/var/lib/scheduled-deploy";

    nodes = {
      # Router - deploy weekly on Sunday at 2 AM
      thebeyond = {
        schedule = "Sun 02:00";
        flakeRef = "git+ssh://git@10.0.100.31/var/lib/git/thebeyond-deploy.git";
      };

      # Second router with different schedule and repo
      # calvard = {
      #   schedule = "Mon 03:00";
      #   flakeRef = "git+ssh://git@10.0.100.31/var/lib/git/calvard-deploy.git";
      # };
    };
  };
}
# ============================================================================
# WRAPPER FLAKE TEMPLATE
# ============================================================================
# Each target needs a git repo with a flake.nix like this:
#
# {
#   inputs = {
#     nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
#     dotfiles.url = "git+ssh://git@10.0.100.31/var/lib/git/dotfiles.git";
#     dotfiles.inputs.nixpkgs.follows = "nixpkgs";
#   };
#   outputs = inputs: {
#     inherit (inputs.dotfiles) nixosConfigurations deploy;
#   };
# }
# ============================================================================
# MONITORING
# ============================================================================
# Each node gets individual systemd units:
#   - scheduled-deploy-thebeyond.service
#   - scheduled-deploy-thebeyond.timer
#
# Check status:
#   systemctl list-timers 'scheduled-deploy-*'
#   systemctl status scheduled-deploy-thebeyond.service
#   journalctl -u scheduled-deploy-thebeyond.service -n 50
#
# Manually trigger:
#   systemctl start scheduled-deploy-thebeyond.service
#
# Deployment history:
#   cd /var/lib/scheduled-deploy/thebeyond
#   git tag -l 'deploy/*' --sort=-creatordate

