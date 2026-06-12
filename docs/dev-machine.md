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
- Interactive agent work runs as the non-root `agent` user (`uid 1000`, home `/home/agent`).
- The container keeps a root-owned bootstrap process only to start `nix-daemon`; agent Nix clients use `NIX_REMOTE=daemon`.
- Nix uses a daemon-style policy with `build-users-group = nixbld`, `allowed-users = root agent`, and `trusted-users = root`; the agent can build but cannot relax daemon policy as a trusted user.
- `/dev/kvm` is passed through for NixOS VM tests.
- Nix sandboxing is enabled with `/dev/kvm` exposed through `extra-sandbox-paths`; `sandbox-fallback` is disabled so builds fail closed rather than silently running unsandboxed.
- Nix daemon UID allocation is enabled (`auto-allocate-uids`, `use-cgroups`, and `uid-range`) so NixOS container tests can run without granting the agent trusted-user status. The devcontainer runs under rootful Podman through DevPod's Docker driver, shares the VM cgroup namespace, bind-mounts `/sys/fs/cgroup` writable for the root-owned daemon, and passes `--security-opt=unmask=/proc/*:/sys/*` so Nix can mount fresh procfs/sysfs instances inside build sandboxes. That exposes more of the KubeVirt VM's `/proc`, `/sys`, and cgroup view to the inner container and weakens inner runtime path masking, so it relies on the VM as the primary boundary; do not replace this with `--privileged` unless this validation path still fails.
- Docker/Podman, DevPod, kubectl, virtctl, and registry credentials are not available inside the agent container.
- Git push access uses a scoped per-session Forgejo bot key injected by `dev-machine up`.
- Egress is enforced at bt8gw for VLAN 51, not by Kubernetes NetworkPolicy. The intended policy is WAN plus limited access to `forgejo.internal` for git/registry traffic.

Residual limitation: this is not a full NixOS-style service manager inside the devcontainer. The image command starts `nix-daemon` directly as a small root bootstrap before DevPod attaches as `agent`. That removes single-user root store writes from normal agent workflows, but the container still needs root at startup and `CAP_SYS_ADMIN` for Nix's sandbox. The `nix` client is still available for repo work; the control is that `agent` is an untrusted daemon user, so it cannot relax daemon policy or add arbitrary trusted substituters. bt8gw egress remains the boundary for what external fetches can reach.

## Podman, Seccomp, And Bubblewrap

Codex runs shell commands through bubblewrap. Bubblewrap needs the `pivot_root` syscall to construct its per-command sandbox. Default container seccomp profiles can block that syscall, which causes commands to fail before the shell starts:

```text
bwrap: pivot_root: Operation not permitted
```

The VM uses rootful Podman as DevPod's Docker-driver runtime. DevPod is pointed at the VM's `podman-rootful` wrapper, which talks to `/run/podman/podman.sock`; invoking plain `podman` as `dev` would otherwise create a rootless workspace. The repo's devcontainer keeps seccomp enabled with a custom profile:

- `.devcontainer/seccomp-codex-bwrap.json` blocks high-risk host/kernel syscalls that are unrelated to this workflow.
- It allows namespace and mount operations needed by Nix and bubblewrap, including `pivot_root`.
- `.devcontainer/devcontainer.json` also passes `--security-opt=unmask=/proc/*:/sys/*`. This weakens Podman's proc/sys path masking, but keeps seccomp and the non-root agent model while avoiding `--privileged`. Without unmasked system paths, Nix's uid-range sandbox can fail when mounting a fresh sysfs inside the build chroot.
- `packages/dev-machine-image/configuration.nix` installs the profile on the VM at `/etc/containers/seccomp-codex-bwrap.json`.
- `.devcontainer/devcontainer.json` passes `--security-opt=seccomp=/etc/containers/seccomp-codex-bwrap.json` to Podman.

After changing the profile, base VM image, dev image, or devcontainer runtime args, start a fresh machine or refresh the existing one as appropriate, then run:

```bash
./scripts/dev-machine-smoke.sh
```

A successful smoke test with no skipped checks, run from a normal devcontainer shell rather than Codex's nested command sandbox, confirms the non-root `agent` session, daemon-backed Nix policy, agent wrapper commands, bubblewrap, Nix sandboxing, UID-range sandbox builds, writable VM cgroup runtime wiring, seccomp, `CAP_SYS_ADMIN`, `/dev/kvm` availability, absence of operator/cluster credentials, and the scoped Forgejo push-key wiring when one was provisioned. A run that reports skipped checks is useful for static/config coverage only; refresh the devcontainer and rerun outside nested command sandboxes before treating runtime changes as validated.

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
