# Router Deployment Options Comparison

This document compares different approaches for deploying NixOS configurations to the router.

## Overview

All options build the configuration **remotely** (not on the router) to avoid requiring build dependencies on the underpowered router hardware.

## Option 1: deploy-rs (Recommended)

**Status**: ✅ Implemented in this flake

### Pros
- Pure flake integration
- Built-in automatic rollback (magicRollback)
- Safe activation testing before setting boot default
- Simple, declarative configuration
- Active community support
- Works well with existing infrastructure

### Cons
- Adds another dependency
- Requires understanding deploy-rs specifics

### Usage
```bash
# Manual deployment
deploy .#thebeyond

# Automated via systemd timer (on VM host)
# See docs/scheduled-deploy-module.md
services.scheduled-deploy.enable = true;
```

### Configuration
Already configured in `flake.nix`:
```nix
deploy.nodes.thebeyond = {
  hostname = "thebeyond.local";
  profiles.system = {
    path = deploy-rs.lib.x86_64-linux.activate.nixos
      self.nixosConfigurations.thebeyond;
    magicRollback = true;
    autoRollback = true;
  };
};
```

## Option 2: nixos-rebuild (Core Nix)

**Status**: Available out of the box

### Pros
- No additional dependencies
- Core NixOS tooling
- Well-documented and stable
- Simple to understand

### Cons
- No automatic rollback protection
- Requires manual activation testing
- Less safety features
- More manual steps needed

### Usage
```bash
# Build locally, deploy remotely
nixos-rebuild switch \
  --flake .#thebeyond \
  --target-host root@thebeyond.local \
  --build-host localhost

# Build on VM host, deploy to router
nixos-rebuild switch \
  --flake .#thebeyond \
  --target-host root@thebeyond.local

# Test before switching
nixos-rebuild test \
  --flake .#thebeyond \
  --target-host root@thebeyond.local

# Then, if successful
nixos-rebuild boot \
  --flake .#thebeyond \
  --target-host root@thebeyond.local
```

### Configuration
None needed - works with any NixOS configuration.

## Option 3: colmena

**Status**: Not implemented

### Pros
- Parallel deployments (useful for multiple routers)
- Deployment keys management
- Meta attributes for host grouping
- Good for complex multi-host setups

### Cons
- More complex than needed for single router
- Different configuration format
- Additional learning curve

### Usage (if implemented)
```bash
colmena apply

# Or specific host
colmena apply --on thebeyond
```

### Configuration (example)
```nix
{
  meta = {
    nixpkgs = import nixpkgs { system = "x86_64-linux"; };
    specialArgs = { inherit inputs; };
  };

  thebeyond = { name, nodes, ... }: {
    deployment = {
      targetHost = "thebeyond.local";
      targetUser = "root";
    };
    imports = [ ./hosts/thebeyond ];
  };
}
```

## Option 4: NixOps

**Status**: Not recommended (legacy)

### Pros
- Mature tooling
- State management
- Infrastructure provisioning

### Cons
- Legacy/community-maintained
- Stateful (requires managing NixOps state)
- Not flake-native
- Overkill for simple deployments

## Option 5: Custom Script + nix copy

**Status**: Could be implemented as alternative

### Pros
- Full control
- No dependencies beyond Nix
- Simple to understand
- Easy to customize

### Cons
- Manual rollback required
- No built-in safety features
- More code to maintain

### Usage (example)
```bash
# Build configuration
nix build .#nixosConfigurations.thebeyond.config.system.build.toplevel

# Copy to router
nix copy --to ssh://thebeyond.local ./result

# Activate (test first)
ssh thebeyond.local "sudo $(readlink ./result)/bin/switch-to-configuration test"

# Then switch
ssh thebeyond.local "sudo $(readlink ./result)/bin/switch-to-configuration switch"
```

## Comparison Table

| Feature | deploy-rs | nixos-rebuild | colmena | NixOps | Custom |
|---------|-----------|---------------|---------|--------|--------|
| Flake support | ✅ Native | ✅ Native | ✅ Native | ⚠️ Limited | ✅ Native |
| Auto rollback | ✅ Yes | ❌ No | ❌ No | ❌ No | ❌ No |
| Remote build | ✅ Yes | ✅ Yes | ✅ Yes | ✅ Yes | ✅ Yes |
| Parallel deploy | ❌ No | ❌ No | ✅ Yes | ✅ Yes | ⚠️ Custom |
| Setup complexity | 🟡 Medium | 🟢 Low | 🔴 High | 🔴 High | 🟡 Medium |
| Safety features | ✅ High | 🟡 Medium | 🟡 Medium | 🟡 Medium | 🔴 Low |
| Dependencies | deploy-rs | None | colmena | NixOps | None |
| Best for | 1-5 hosts | 1-3 hosts | 10+ hosts | Legacy | Custom needs |

## Recommendation

**Use deploy-rs** (already implemented) because:

1. **Safety**: Automatic rollback protects against bad deployments
2. **Simplicity**: Simple configuration, well-integrated with flakes
3. **Testing**: Built-in testing before activation
4. **Scalability**: Works well for 1-5 hosts (fits your setup)
5. **Active development**: Well-maintained, good community support

**Alternative**: If you want to avoid dependencies, `nixos-rebuild` is perfectly fine, but requires manual safety steps:
```bash
# Always test first
nixos-rebuild test --flake .#thebeyond --target-host thebeyond.local

# Verify it works
ssh thebeyond.local 'systemctl status'

# Then make it permanent
nixos-rebuild boot --flake .#thebeyond --target-host thebeyond.local

# Reboot when convenient
ssh thebeyond.local 'reboot'
```

## Testing Before Deployment

Regardless of deployment method, always:

1. **Run integration tests**: `nix build .#checks.x86_64-linux.router6-*`
2. **Build locally first**: `nix build .#nixosConfigurations.thebeyond.config.system.build.toplevel`
3. **Test activation**: Use `test` instead of `switch` first
4. **Have console access**: Keep a way to recover if SSH breaks

## Automation

For automated deployments:

1. **deploy-rs** (implemented): Use the systemd timer module
2. **nixos-rebuild**: Create a similar systemd service
3. **CI/CD**: GitHub Actions, Gitea Actions, etc.

Example automated workflow:
```
git push → CI runs tests → CI deploys to router → Auto-rollback if fails
```

## Future Considerations

- **Multiple routers**: If you add more routers (calvard), deploy-rs can handle them easily
- **CI/CD integration**: deploy-rs works well with GitHub Actions
- **Monitoring**: Add deployment notifications/alerts
- **Canary deployments**: Test on one router before others
