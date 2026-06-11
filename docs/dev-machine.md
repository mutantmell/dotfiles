# Dev Machine

The dev-machine is an ephemeral KubeVirt VM that runs a DevPod-managed devcontainer for AI-assisted development. The VM is the primary security boundary; the inner container still keeps defense-in-depth settings where they do not break the workflow.

## Lifecycle

Operator-side commands are provided by the Home Manager `programs.dev-machine` wrapper. These commands run on the operator workstation, not inside the agent devcontainer.

```bash
# Create or recreate a dev-machine for a repo. Omitting the repo uses the current checkout's origin.
dev-machine up [<repo-url-or-path>] [--name <name>]

# Attach to the running devcontainer.
dev-machine ssh <name>

# Recreate only the devcontainer on the existing VM. Use after devcontainer.json or dev image changes.
dev-machine refresh <name>

# Open the VM serial console.
dev-machine console <name>

# Recover a wedged but still-running VM/devcontainer and back up the worktree first.
dev-machine rescue <name>

# Tear down the workspace, VM, and scoped push credential.
dev-machine down <name>

# Rebuild and publish the thin base VM image.
dev-machine publish-base
```

## Runtime Contract

Inside the devcontainer, agents should expect:

- `nix`, `git`, `rg`, `jq`, `treefmt`, `alejandra`, `openssh`, Codex, and Claude are available.
- `/dev/kvm` is passed through for NixOS VM tests.
- Nix sandboxing is enabled with `/dev/kvm` exposed through `extra-sandbox-paths`.
- Docker, DevPod, kubectl, virtctl, and registry credentials are not available inside the agent container.
- Git push access uses a scoped per-session Forgejo bot key injected by `dev-machine up`.

## Seccomp And Bubblewrap

Codex runs shell commands through bubblewrap. Bubblewrap needs the `pivot_root` syscall to construct its per-command sandbox. Docker's default seccomp profile blocks that syscall, which causes commands to fail before the shell starts:

```text
bwrap: pivot_root: Operation not permitted
```

The repo's devcontainer keeps seccomp enabled with a custom profile:

- `.devcontainer/seccomp-codex-bwrap.json` blocks high-risk host/kernel syscalls that are unrelated to this workflow.
- It allows namespace and mount operations needed by Nix and bubblewrap, including `pivot_root`.
- `packages/dev-machine-image/configuration.nix` installs the profile on the VM at `/etc/docker/seccomp-codex-bwrap.json`.
- `.devcontainer/devcontainer.json` passes `--security-opt=seccomp=/etc/docker/seccomp-codex-bwrap.json` to Docker.

After changing the profile, base VM image, dev image, or devcontainer runtime args, start a fresh machine or refresh the existing one as appropriate, then run:

```bash
./scripts/dev-machine-smoke.sh
```

A successful smoke test confirms bubblewrap, Nix sandboxing, seccomp, `CAP_SYS_ADMIN`, and `/dev/kvm` availability.

## Validation

For repo validation inside a dev-machine, use:

```bash
./scripts/agent-preflight.sh --quick
./scripts/agent-preflight.sh --full
```

Do not use `nix flake check` for normal validation; this flake's large set of NixOS evaluations can OOM in a single evaluator process. `scripts/run-checks.sh` runs checks as separate `nix build` invocations.
