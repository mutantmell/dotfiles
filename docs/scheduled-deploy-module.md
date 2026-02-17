# Scheduled Deploy Module

A NixOS module for automated deployments via deploy-rs, using wrapper flake repos for independent update cadences per target.

## Overview

Each deployment target has a **wrapper flake** in its own git repository. The module clones these repos on the VM host, updates their inputs on a schedule, and deploys via deploy-rs with automatic rollback. This decouples each target's nixpkgs version from the main dotfiles flake.

## Prerequisites

### Wrapper Flake Repo

Each target needs a git repo containing a wrapper `flake.nix`. For example, to deploy the router (yggdrasil):

```nix
# flake.nix in the yggdrasil-deploy repo
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    dotfiles.url = "git+ssh://git@10.0.100.31/var/lib/git/dotfiles.git";
    dotfiles.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = inputs: {
    inherit (inputs.dotfiles) nixosConfigurations deploy;
  };
}
```

Create the repo and do an initial `nix flake update` to generate the first `flake.lock`:

```bash
# On the gitea server or wherever you host git repos
git init --bare /var/lib/git/yggdrasil-deploy.git

# On your workstation
git clone ssh://git@10.0.100.31/var/lib/git/yggdrasil-deploy.git
cd yggdrasil-deploy
# Create flake.nix as above
nix flake update
git add flake.nix flake.lock
git commit -m "Initial wrapper flake"
git push
```

### SSH Access

The VM host needs SSH access to:
- The git repo (for clone/pull/push)
- The deployment target (for deploy-rs)

## Configuration

### Basic Usage

```nix
{
  imports = [ ../../modules/scheduled-deploy ];

  services.scheduled-deploy = {
    enable = true;
    nodes.yggdrasil = {
      schedule = "Sun 02:00";
      flakeRef = "git+ssh://git@10.0.100.31/var/lib/git/yggdrasil-deploy.git";
    };
  };
}
```

### All Options

```nix
services.scheduled-deploy = {
  enable = true;

  # Where local checkouts are stored (default shown)
  stateDirectory = "/var/lib/scheduled-deploy";

  nodes = {
    yggdrasil = {
      # Systemd calendar expression (required)
      schedule = "Sun 02:00";

      # Git URL of the wrapper flake repo (required)
      flakeRef = "git+ssh://git@10.0.100.31/var/lib/git/yggdrasil-deploy.git";

      # deploy-rs node name (defaults to attr name)
      # deployNode = "yggdrasil";
    };
  };
};
```

## How It Works

On each scheduled run, the service:

1. **Clones or pulls** the wrapper flake repo to a local checkout
2. **Updates flake inputs** via `nix flake update` (gets latest nixpkgs + dotfiles)
3. **Commits and pushes** the updated `flake.lock` (skipped if no changes)
4. **Deploys** via `deploy .#<node>` (builds locally on the VM host, pushes to target with rollback)
5. **Tags** the repo with `deploy/<node>/<timestamp>` on success

## Systemd Units

Each node gets individual units:
- `scheduled-deploy-<node>.service` — the deployment oneshot
- `scheduled-deploy-<node>.timer` — triggers on schedule with `Persistent = true` and `RandomizedDelaySec = 1h`

### Monitoring

```bash
# Check timer status
systemctl list-timers 'scheduled-deploy-*'

# Service status
systemctl status scheduled-deploy-yggdrasil.service

# Recent logs
journalctl -u scheduled-deploy-yggdrasil.service -n 50

# Follow logs live
journalctl -u scheduled-deploy-yggdrasil.service -f
```

### Manual Trigger

```bash
systemctl start scheduled-deploy-yggdrasil.service
journalctl -u scheduled-deploy-yggdrasil.service -f
```

### Deployment History

The wrapper flake repo records all activity:

```bash
# View deployment tags
cd /var/lib/scheduled-deploy/yggdrasil
git tag -l 'deploy/*' --sort=-creatordate

# See what changed between two deployments
git diff deploy/yggdrasil/20260208T020000Z deploy/yggdrasil/20260215T020000Z

# View input update history
git log --oneline
```

## Persistence

If your host uses impermanence, ensure the state directory persists so local checkouts survive reboots:

```nix
environment.persistence."/persist" = {
  directories = [
    "/var/lib/scheduled-deploy"
  ];
};
```

Without persistence, the first run after reboot will do a fresh `git clone` (safe, just slower).

## Multi-Node Deployment

Each node is fully independent with its own repo, checkout, schedule, and deployment:

```nix
services.scheduled-deploy = {
  enable = true;
  nodes = {
    yggdrasil = {
      schedule = "Sun 02:00";
      flakeRef = "git+ssh://git@10.0.100.31/var/lib/git/yggdrasil-deploy.git";
    };
    vanaheim = {
      schedule = "Mon 03:00";
      flakeRef = "git+ssh://git@10.0.100.31/var/lib/git/vanaheim-deploy.git";
    };
  };
};
```

## Scheduling Examples

```nix
schedule = "Sun 02:00";            # Every Sunday at 2 AM
schedule = "daily";                # Every day at midnight
schedule = "weekly";               # Every Monday at midnight
schedule = "*-*-* 00/6:00:00";    # Every 6 hours
schedule = "*-*-01 03:00:00";     # First of every month at 3 AM
```

All timers include a 1-hour random delay to avoid exact timing.
