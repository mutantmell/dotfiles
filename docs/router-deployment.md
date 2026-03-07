# Router Deployment Strategy

This documents the automated deployment strategy for the router (thebeyond).

## Overview

The router is deployed using **deploy-rs**, a pure flake-based deployment tool with built-in rollback support. This ensures safe, tested deployments to the router without requiring it to build its own configuration locally.

## Architecture

```
VM Host (builder)  -->  Build configuration
                   -->  Run tests
                   -->  Deploy via deploy-rs
                   -->  Router activates with auto-rollback
```

## Manual Deployment

### Deploy from the Dotfiles Flake

```bash
# Deploy to thebeyond using the main flake's pinned inputs
deploy .#thebeyond
```

This builds locally and deploys with auto-rollback enabled.

### Run Tests First

```bash
# Run integration tests before deploying
nix flake check

# Or run specific tests
nix build .#checks.x86_64-linux.router6-ipv6
nix build .#checks.x86_64-linux.router6-firewall
```

## Automated Deployment

The `scheduled-deploy` module deploys the router on a weekly schedule using deploy-rs, with automatic rollback protection. Each target has a **wrapper flake** in its own git repo, giving it an independent `flake.lock` for nixpkgs pinning.

### How It Works

The module maintains a local checkout of the wrapper flake repo on the VM host. On each scheduled run, it:

1. Pulls the latest wrapper flake from git
2. Runs `nix flake update` (updates nixpkgs + dotfiles inputs)
3. Commits and pushes the updated `flake.lock`
4. Deploys via deploy-rs (builds locally, pushes to router, automatic rollback)
5. Tags the repo on successful deployment

### Prerequisites

Create a wrapper flake repo for the router (see `docs/scheduled-deploy-module.md` for details).

### Configuration

```nix
# hosts/remiferia/scheduled-deploy.nix
{ ... }:
{
  imports = [ ../../modules/scheduled-deploy ];

  services.scheduled-deploy = {
    enable = true;
    nodes.thebeyond = {
      schedule = "Sun 02:00";
      flakeRef = "git+ssh://git@10.0.100.31/var/lib/git/thebeyond-deploy.git";
    };
  };
}
```

Then import it:

```nix
# hosts/remiferia/default.nix
{
  imports = [
    # ... existing imports ...
    ./scheduled-deploy.nix
  ];
}
```

### Monitoring

```bash
# Check timer status
systemctl list-timers 'scheduled-deploy-*'

# View logs
journalctl -u scheduled-deploy-thebeyond.service -n 50

# Manually trigger
systemctl start scheduled-deploy-thebeyond.service

# View deployment history
cd /var/lib/scheduled-deploy/thebeyond
git tag -l 'deploy/*' --sort=-creatordate
```

### Multiple Routers

```nix
services.scheduled-deploy = {
  enable = true;
  nodes = {
    thebeyond = {
      schedule = "Sun 02:00";
      flakeRef = "git+ssh://git@10.0.100.31/var/lib/git/thebeyond-deploy.git";
    };
    calvard = {
      schedule = "Mon 03:00";
      flakeRef = "git+ssh://git@10.0.100.31/var/lib/git/calvard-deploy.git";
    };
  };
};
```

Each node has its own repo, lock file, and deployment schedule.

## Testing Before Deployment

The deployment process includes comprehensive testing:

### Integration Tests

Located in `tests/`, these verify:

- IPv6 addressing
- Firewall rules
- Bond/bridge configuration
- VLAN ordering
- Disko profiles

Run manually:

```bash
nix build .#checks.x86_64-linux.router6-ipv6
nix build .#checks.x86_64-linux.router6-firewall
# etc.
```

### Build Verification

Before deploying, the script builds the full system closure to ensure it evaluates correctly:

```bash
nix build .#nixosConfigurations.thebeyond.config.system.build.toplevel
```

### Deploy-rs Checks

The flake includes deploy-rs validation:

```bash
nix flake check
```

This ensures the deploy configuration is valid.

## Rollback Safety

deploy-rs includes automatic rollback protection:

1. **magicRollback**: Activates the new configuration but doesn't set it as boot default
2. **autoRollback**: If the host becomes unreachable during activation, it automatically reverts

If something goes wrong:

- The router will automatically rollback to the previous generation
- You can manually rollback: `ssh thebeyond 'sudo nixos-rebuild --rollback switch'`
- Check previous generations: `ssh thebeyond 'nix-env --list-generations --profile /nix/var/nix/profiles/system'`

## Deployment Workflow

### Standard Workflow

1. Make changes to router configuration locally
2. Test changes: `nix build .#nixosConfigurations.thebeyond.config.system.build.toplevel`
3. Run integration tests: `nix build .#checks.x86_64-linux.router6-ipv6` (etc.)
4. Deploy: `deploy .#thebeyond`
5. Verify: `ssh thebeyond.local 'nixos-version'`

### Emergency Rollback

If something goes wrong and auto-rollback doesn't work:

```bash
# SSH into router
ssh thebeyond.local

# List generations
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Rollback to previous
sudo nixos-rebuild --rollback switch

# Or rollback to specific generation
sudo /nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration switch
```

## Remote Building

deploy-rs builds the configuration on the machine you run it from, not on the router. This means:

- The VM host needs sufficient resources to build NixOS configurations
- The router stays lightweight and doesn't need build dependencies
- You can build on your workstation and deploy remotely

## Flake Structure

The deployment configuration is in `flake.nix`:

```nix
deploy.nodes.thebeyond = {
  hostname = "thebeyond.local";
  profiles.system = {
    sshUser = "root";
    user = "root";
    path = deploy-rs.lib.x86_64-linux.activate.nixos
      self.nixosConfigurations.thebeyond;
    magicRollback = true;
    autoRollback = true;
  };
};
```

## Troubleshooting

### SSH Connection Issues

Ensure SSH keys are configured:

```bash
ssh-add ~/.ssh/id_ed25519  # or your deploy key
ssh root@thebeyond.local 'echo connected'
```

### Build Failures

Check the build locally first:

```bash
nix build .#nixosConfigurations.thebeyond.config.system.build.toplevel
```

### Test Failures

Run tests individually to identify issues:

```bash
nix build .#checks.x86_64-linux.router6-ipv6
# Check the output for errors
```

### Deployment Stuck

If deployment hangs:

1. Check router is reachable: `ping thebeyond.local`
2. Check SSH access: `ssh root@thebeyond.local`
3. Cancel deployment (Ctrl+C) - auto-rollback should trigger
4. Manually rollback if needed (see Emergency Rollback above)

## Alternative: Core Nix Approach

If you prefer not to use deploy-rs, you can use pure `nixos-rebuild`:

```bash
# Build locally, deploy remotely
nixos-rebuild switch \
  --flake .#thebeyond \
  --target-host root@thebeyond.local \
  --build-host localhost

# Or build and deploy on the VM host
nixos-rebuild switch \
  --flake .#thebeyond \
  --target-host root@thebeyond.local
```

However, this lacks the automatic rollback features of deploy-rs.

## Future Enhancements

Potential improvements:

- [ ] Add deployment notifications (email, webhook, etc.)
- [ ] Integrate with CI/CD (GitHub Actions, Gitea Actions, etc.)
- [ ] Pre-deployment configuration diff
- [ ] Deployment metrics and logging
- [ ] Support for deploying multiple routers in sequence
- [ ] Integration with OpenWrt devices
