This document is for me (the operator) to put down open questions. LLM Agents can resolve items in here by adding, at the end of a line, either (resolved) for items that are resolved, or (planned) for items that are captured in plans, but MUST NOT do any further editing. It is important that this remain a place I can put down raw notes.

- dev-machine up enhancements:
  - add zellij and wezterm?
  - don't unconditionally push the image (detect when not changed?)
  - have a "refresh" command to tear down and setup?0
  - check the current repo for a git reference if a url isn't provided?
	- maybe also a devcontainers file.
	- autoresolve the name?
  - how can we clean up the image repo, so it doesn't get gunked up with garbage?
  - clean up errors on startup (see below)
  - other enhancements/changes (CLI improvements?)
  - better authelia integration (without copy/pasting a token from a uri)
  - how do I access a dev machine from rootpod? Should we be giving them generated host-names and DNS entries?
  - prevent nix shell from being able to install additional things into the container, while allowing the flake in this dotfiles to be build
  - how do we get claude to better be able to one-shot things, without requiring many permissions checks, now that we're not running on an operator machine?
  - run on cloud-hypervisor, not qemu?
- macvlan on erebonia for all of k3s (to enable better lockdowns)
- remove kata entirely (unless needed, but current use-cases are supported better by KubeVirt)
- once this is enabled, we should figure out what containers go to what VLANs (everything lives off of erebonia's MGMT ip address, it bypasses a lot)
- how can we better handle versions and versioning in the k3s system? Ideally no versions/hashes in the core hosts definition, similar to how the nixpkgs integration goes.
- do we want to move things away from 'services.k3s.autoDeployCharts' and move them to flux2 integrations?
  - we want a non-flake managed set of flux dependencies to install, so that CI can own a particular path for doing dependency updates, and we can auto-reject changes that stray outside that narrow path
  - what in general is the dividing line between 'autoDeployCharts' and flux?
- how do we move the forgejo backing data to be stored on liberl via NFS?
- now that keycloak is split into lldap and authelia, authelia should be safe to move into the app tier for more general access (it's essentially read-only)

errors:
17:48:26 info Creating devcontainer...
17:48:34 info Clone repository
17:48:34 info URL: https://forgejo.internal/mutantmell/dotfiles
17:48:34 done Successfully cloned repository
17:48:34 info Configuring docker daemon ...
17:48:34 warn Could not find docker daemon config file, if using the registry cache, please ensure the daemon is configured with containerd-snapshotter=true
17:48:34 warn More info at https://docs.docker.com/engine/storage/containerd/
17:48:35 info Inspecting image forgejo.internal/mutantmell/dev-machine-dev:latest
17:48:35 info Image forgejo.internal/mutantmell/dev-machine-dev:latest not found
17:48:35 info Pulling image forgejo.internal/mutantmell/dev-machine-dev:latest
17:48:56 info 05de3fbd7e5498ab79d7ed0f8098a3fa45b86d413ba2c682afd523aa92a67bdd
17:48:56 info Setup container...
17:48:56 info Chown workspace...
17:48:56 info Chown projects...
17:48:56 info Run command : git config --global --add safe.directory /workspaces/test...
17:48:56 done Successfully ran command : git config --global --add safe.directory /workspaces/test
17:48:56 info Run 'ssh test.devpod' to ssh into the devcontainer
==> provisioning scoped push credential (cc SSH key for mutantmell/dotfiles)
git 17:48:58 error Error tunneling to container: wait: remote command exited without exit status or exit signal

dev machine 'test' is up. Connect with:  dev-machine ssh test

also errors on disconnect:

bash-5.3#
logout
17:53:29 error Error tunneling to container: wait: remote command exited without exit status or exit signal
17:53:29 error Try using the --debug flag to see a more verbose output
17:53:29 fatal tunnel to container: run in container: ssh session: Process exited with status 1
