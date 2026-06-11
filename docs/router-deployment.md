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
# Run the standard check suite before deploying
./scripts/run-checks.sh

# Or run focused checks while iterating
nix build .#checks.x86_64-linux.router6-ipv6 --print-build-logs
nix build .#checks.x86_64-linux.router6-firewall --print-build-logs
```

Do not use `nix flake check` here. This flake has many NixOS evaluations and
can OOM during broad flake checking; the wrapper runs checks as separate
`nix build` processes.

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
nix build .#checks.x86_64-linux.router6-ipv6 --print-build-logs
nix build .#checks.x86_64-linux.router6-firewall --print-build-logs
# etc.
```

### Build Verification

Before deploying, the script builds the full system closure to ensure it evaluates correctly:

```bash
nix build .#nixosConfigurations.thebeyond.config.system.build.toplevel
```

### Full Check Suite

Run the repository check wrapper when you need the full suite, including
deploy-rs validation:

```bash
./scripts/run-checks.sh
```

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
3. Run checks: `./scripts/run-checks.sh` or targeted `nix build .#checks.x86_64-linux.<name> --print-build-logs`
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
nix build .#checks.x86_64-linux.router6-ipv6 --print-build-logs
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
