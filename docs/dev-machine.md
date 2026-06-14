# Dev Machine

The dev-machine is an ephemeral KubeVirt VM that runs a DevPod-managed devcontainer for AI-assisted development. The VM is the primary security boundary; the inner container still keeps defense-in-depth settings where they do not break the workflow.

## Lifecycle

Operator-side commands are provided by the standalone `dev-machine` package. Home Manager's `programs.dev-machine` module installs that package and writes `$XDG_CONFIG_HOME/dev-machine/config.json`. These commands run on the operator workstation, not inside the agent devcontainer.

```bash
# Create or recreate a dev-machine for a repo. Omitting the repo uses the current checkout's origin.
dev-machine up [<repo-url-or-path>] [--name <name>]

# Attach to the running devcontainer.
dev-machine ssh <name>

# Recreate only the devcontainer on the existing VM. Use after devcontainer.json-only changes.
dev-machine refresh <name>

# Open the VM serial console.
dev-machine console <name>

# Recover a wedged but still-running VM/devcontainer and back up the worktree first.
dev-machine rescue <name>

# Tear down the workspace, VM, and scoped push credential.
dev-machine down <name>

# Rebuild and publish the base VM image.
dev-machine publish-base
```

## Runtime Contract

Inside the devcontainer, agents should expect:

- `nix`, `git`, `rg`, `jq`, `treefmt`, `alejandra`, `openssh`, Codex, and Claude are available.
- Interactive agent work runs as the non-root `agent` user (`uid 1000`, home `/home/agent`).
- The container bind-mounts the VM host `/nix`; agent Nix clients use `NIX_REMOTE=daemon` and talk to the VM host nix-daemon.
- Nix uses a daemon-style policy on the VM host with `build-users-group = nixbld`, `allowed-users = root dev`, and `trusted-users = root`; the container's `agent` uid maps to the VM host's `dev` uid and can build but cannot relax daemon policy as a trusted user.
- `/dev/kvm` is passed through for NixOS VM tests.
- Nix sandboxing is enabled with `/dev/kvm` exposed through `extra-sandbox-paths`; `sandbox-fallback` is disabled so builds fail closed rather than silently running unsandboxed.
- Nix daemon UID allocation is enabled on the VM host (`auto-allocate-uids`, `use-cgroups`, and `uid-range`) so NixOS container tests can run without granting the agent trusted-user status. The devcontainer no longer needs `CAP_SYS_ADMIN`, cgroup namespace sharing, writable `/sys/fs/cgroup`, system-path unmasking, or `--privileged` for Nix builds because sandbox setup happens in the VM host daemon.
- Docker/Podman, DevPod, kubectl, virtctl, and registry credentials are not available inside the agent container.
- Git push access uses a scoped per-session Forgejo bot key injected by `dev-machine up`.
- LLM profile setup is injected through DevPod dotfiles when the target repo's `.net.mutantmell/agents.toml` names a dotfiles repository. That repository's installer activates only the skills and marketplaces the checkout asks for.
- Egress is enforced at bt8gw for VLAN 51, not by Kubernetes NetworkPolicy. The intended policy is WAN plus limited access to `forgejo.internal` for git/registry traffic.

The VM's 60GiB scratch disk backs the mutable runtime state: the base image copies the complete `/nix` tree to scratch at boot, bind-mounts it back over `/nix` before `nix-daemon` starts, and also keeps rootful Podman storage plus `build-dir = /mnt/scratch/nix-builds` on scratch. That build directory is root-owned and not world-writable because Nix rejects insecure configured build roots. Inside the agent devcontainer, `nix config show build-dir` reports the client-side override setting and may be empty; it is not a reliable view of the host daemon's private build root. The root containerDisk stays closure-sized and reproducible; `dev-machine up --disk <size>` is the capacity knob for store growth, build workdirs, and container layers.

## Podman, Seccomp, And Bubblewrap

Codex runs shell commands through bubblewrap. Bubblewrap needs the `pivot_root` syscall to construct its per-command sandbox. Default container seccomp profiles can block that syscall, which causes commands to fail before the shell starts:

```text
bwrap: pivot_root: Operation not permitted
```

The VM uses rootful Podman as DevPod's Docker-driver runtime. DevPod is pointed at the VM's `podman-rootful` wrapper, which talks to `/run/podman/podman.sock`; invoking plain `podman` as `dev` would otherwise create a rootless workspace. The repo's devcontainer keeps Podman's default seccomp profile enabled.

The devcontainer bind-mounts `/nix` from the VM host. Normal shell commands still run inside the non-root `agent` container, but Nix builds execute through the host daemon. `scripts/dev-machine-smoke.sh` verifies seccomp is active, bubblewrap can construct its `pivot_root` sandbox from a non-nested devcontainer shell, and the host-daemon uid-range build path completes.

After changing the base VM image, dev image, or devcontainer runtime args, start a fresh machine or refresh the existing one as appropriate, then run:

```bash
./scripts/dev-machine-smoke.sh
```

A successful smoke test with no skipped checks, run from a normal devcontainer shell rather than Codex's nested command sandbox, confirms the non-root `agent` session, VM-host daemon-backed Nix policy, agent wrapper commands, bubblewrap, Nix sandboxing, UID-range sandbox builds, seccomp, `/dev/kvm` availability, absence of operator/cluster credentials, and the scoped Forgejo push-key wiring when one was provisioned. A run that reports skipped checks is useful for static/config coverage only; refresh the devcontainer and rerun outside nested command sandboxes before treating runtime changes as validated.

Container-backed NixOS tests are currently a side-by-side proof of concept, not a replacement for the VM tests. Tests that assert firewall or service behavior should be directly comparable, but topology tests that create host-kernel netdevs such as batman-adv, bonds, bridges, and VLANs can still depend on the builder host kernel and loaded modules. Keep the VM variants as the authoritative coverage until those cases have been reviewed on the final dev-machine image.

To also probe the expected bt8gw egress shape from a non-nested shell, run:

```bash
./scripts/dev-machine-smoke.sh --network
```

That optional mode checks WAN HTTPS plus `forgejo.internal` SSH/HTTPS reachability, and verifies a non-creil internal HTTPS target is not reachable. It is intentionally not part of the default smoke path because Codex's per-command sandbox can hide DNS/network access even when the devcontainer itself is correctly configured.

## Validation

For repo validation inside a dev-machine, use:

```bash
agent-preflight-quick
agent-preflight-full
```

The dev image also exposes thin repo-local wrappers for common agent tasks:

```bash
agent-fmt                         # nix fmt
agent-preflight [--quick|--full]  # ./scripts/agent-preflight.sh
agent-checks [check ...]          # ./scripts/run-checks.sh
agent-build-check <check-name>    # nix build .#checks.x86_64-linux.<check-name>
agent-smoke [--network]           # ./scripts/dev-machine-smoke.sh
```

These commands locate the dotfiles checkout, change to the repo root, and call the existing scripts or Nix commands. They do not replace the repo validation stack.

Do not use `nix flake check` for normal validation; this flake's large set of NixOS evaluations can OOM in a single evaluator process. `scripts/run-checks.sh` runs checks as separate `nix build` invocations, and `agent-checks` is the PATH wrapper around it.

## Agent Profile

`dev-machine up` reads the target repo's `.net.mutantmell/agents.toml` before starting DevPod. This repo uses:

```toml
profile = "default"

[dotfiles]
url = "ssh://forgejo@forgejo.internal/mutantmell/agents.git"
script = "install.sh"
```

When `dotfiles.url` is present, the wrapper passes that repository to DevPod as dotfiles:

```bash
devpod up ... --dotfiles ssh://forgejo@forgejo.internal/mutantmell/agents.git --dotfiles-script install.sh
```

The agents repository is a catalog and installer, not a checked-in home directory. Each target repo chooses its own profile source, skills, and marketplaces with `.net.mutantmell/agents.toml`; this repo currently enables the Nix flake, NixOS VM test, Forgejo AGit, and dev-machine skills. The manifest is intentionally under a private hidden namespace to avoid colliding with future generic agent standards.

The agents dotfiles repository must be readable during `devpod up`. That happens
before `dev-machine up` injects the per-session Forgejo push key into the
devcontainer, so the push key cannot bootstrap access to the profile repository.
Keep the configured agents repository readable through the normal DevPod clone
path. `programs.dev-machine.agentsDotfiles.url` remains available as an
operator-side fallback for repositories that do not yet carry an agents manifest,
but repo-local `dotfiles.url` is the preferred source of truth.
