# Locked-down AI Dev Machines on KubeVirt (devpod + devcontainer.json)

Status: In progress — Phase 1 (KubeVirt platform + thin base VM image) and
Phase 2 (`devcontainer.json` + custom Nix dev image) landed. Next: Phase 3
(devpod wiring + operator scripting).

**What this is:** ephemeral, locked-down **dev machines** for LLM coding
agents — spin up a VM-isolated workspace from a repo's `devcontainer.json`,
let an agent edit code and **push to a branch**, with **no other reach** into
the homelab. The agent must be able to run this flake's `nixosTest` suite
**inside** the workspace (fast local feedback), which makes **nested
virtualization a hard requirement**.

**What this is NOT:** the migration of the existing mutable workstations
**edith** and **trista** off Incus. That is a different shape (long-lived,
fully-fledged NixOS workstations where the operator runs things) and is
tracked separately — see `llm-notes/plans/incus-workstation-migration-plan.md`.
The two plans **share the KubeVirt platform component** (Phase 1 here is also a
prerequisite there); coordinate which lands it.

Supersedes the dev-container portion of
`llm-notes/wip/k3s-cluster-workloads-plan.md` **Phase A** — that section's
"default to `kata-clh` (validated)" + custom nested-virt guest kernel is
**replaced** by the KubeVirt-VM substrate decided here (see "Decision" below).
The Phase-A PoC stands as proof the *cluster* works; the *runtime substrate*
changes.

Depends on:

- `llm-notes/done/k3s-cluster-bootstrap-plan.md` — the cluster, OIDC, host
  firewall, flannel CNI, the NetworkPolicy controller.
- Apiserver OIDC (landed 2026-06-05, workloads-plan Phase A prerequisite) —
  the operator drives `devpod`/`kubectl` with their existing Authelia identity.

---

## Decision (item 1) — KubeVirt VM as the boundary; devpod runs the devcontainer *inside* it; drop the kata-clh custom kernel

The substrate is a **KubeVirt `VirtualMachine`** (regular NixOS kernel, KVM
enabled). erebonia's host is already `kvm_intel nested=1`, so **nested virt is
native inside the VM** — the flake's `nixosTest`s get `/dev/kvm` with no
custom kernel. This **retires the from-source kata-clh nested guest kernel**
(`hosts/erebonia/k3s/runtimes.nix` `nestedKataKernel*` / `kataClhConfig`) for
the dev-machine use case — the maintenance burden (rebuilding the guest kernel
from kernel.org on every kata bump, plus the unproven `vmlinux` extraction)
goes away. This also rides the industry direction (KubeVirt; the
container/VM convergence the operator is betting on — KubeVirt v1.8's
Hypervisor Abstraction Layer is an early signal) instead of fighting it with
bespoke kata work.

`devcontainer.json` stays the interface — it was the whole reason to prefer
devpod over a bespoke tool. The reconciliation that makes "real VM" and
"devcontainer.json standard" coexist:

```
operator workstation                 erebonia (k3s + KubeVirt)
  dev-machine up <repo>  ──────────►  KubeVirt VM  (boundary + nested /dev/kvm)
  (home-manager wrapper)               ├─ sshd + docker (thin base image)
        │                              └─ devpod runs devcontainer.json here:
        │  devpod ssh provider ───────────►  runc container (no isolation
        │  (passwordless SSH, docker grp)     needed — VM is the boundary)
        │                                     runArgs: ["--device=/dev/kvm"]
        │                                     → ./scripts/run-checks.sh works
```

- **devpod's SSH provider** (`devpod provider add ssh -o HOST=…`) targets the
  VM. It needs passwordless SSH and the user in the `docker` group; it builds/
  runs the `devcontainer.json` as a plain **runc** container under the VM's
  docker. Container isolation is irrelevant — the VM is the security boundary.
- `devcontainer.json` carries `"runArgs": ["--device=/dev/kvm"]`, surfacing the
  VM's `/dev/kvm` into the inner container so VM tests run with fast feedback.
- **VM lifecycle:** start with a small script (in the home-manager wrapper)
  that creates the `VirtualMachine` and points the SSH provider at it.
  **Graduation:** a thin **custom devpod KubeVirt provider** (the documented
  provider spec — `provider.yaml` + a ~100-line CLI over `virtctl`/`kubectl`)
  so `devpod up`/`down` owns the VM lifecycle end-to-end. That is
  standard-tooling extension, **not** a cc-sandbox redux.

### Rejected alternatives

- **devpod kubernetes *driver*.** Creates an ordinary **Pod**, not a KubeVirt
  VM, and has no KubeVirt awareness — it cannot place the workload inside the
  VM, and a pod gets in-microVM `/dev/kvm` only via the kata custom kernel we
  are retiring. (This was the core misconception: installing KubeVirt in the
  cluster does **not** make k8s-driver pods run as VMs.)
- **Bypass devpod, cc-sandbox-style self-setup in the VM.** Loses the
  `devcontainer.json` standard and reintroduces bespoke orchestration (the
  1100-line Python + hand-rolled OIDC + hand-tuned cgroup/seccomp in
  `packages/cc-sandbox` / `deployd-helper/src/validation.rs`) — the exact
  tooling we're leaving behind.
- **KubeVirt's own cloud-hypervisor backend.** Under development only
  (v1.8 HAL, not production) — KubeVirt is QEMU/KVM via libvirt today. Not a
  current option; QEMU/KVM in the VM is fine (the *guest's* KVM is what runs
  the nested tests, not the host VMM).

---

## Phase 1 — KubeVirt platform + thin base VM image

1. **Add KubeVirt to the platform.** kubevirt-operator + virt-handler
   DaemonSet (runs on erebonia, the single node) as a HelmChart in the k3s
   server manifests dir (`/var/lib/rancher/k3s/server/manifests/`, declared in
   the flake, pinned) — same pattern as `cert-manager.nix` / `kyverno.nix` /
   `flux.nix`. CRDs: `VirtualMachine`, `VirtualMachineInstance`. **This plan
   owns this HelmChart** (decision 6); `incus-workstation-migration-plan.md`
   Phase 7.1 depends on it rather than landing its own.
2. **Host prerequisites.** Confirm `kvm_intel nested=1` on erebonia (already
   set per `project_kata_guest_kernel_no_nested_kvm`); enable the KubeVirt
   nested-virt feature gate if required.
3. **Thin base VM image.** A flake-built minimal NixOS **containerDisk** (or
   DataVolume) carrying only what devpod's SSH provider needs: `sshd`,
   `docker` (or podman with docker-compat), and a service user in the `docker`
   group. **containerDisk** (ephemeral, pulled from `creil`) fits the
   ephemeral-sandbox model and needs **no CSI** — CSI/DataVolume durability is
   the edith/trista path, deferred there. The image is deliberately thin: the
   *dev tooling* lives in the devcontainer image (Phase 2), not the VM. VM =
   boundary + docker + sshd.

## Phase 2 — `devcontainer.json` + custom dev image (item 2) — DONE

Landed as `.devcontainer/devcontainer.json` (image pinned to
`forgejo.internal/mutantmell/dev-machine-dev:latest`, `runArgs:
["--device=/dev/kvm"]`, no features) + `packages/dev-machine-dev-image/`
(`dockerTools.streamLayeredImage`, `includeNixDB = true`), exposed as the
`dev-machine-dev-image` flake package. Publish is the operator/CI `skopeo copy`
step documented in the package header. Implementation decisions:

- **`kubectl` excluded** from the image — Phase 3's lockdown wins over the
  Phase-2.2 listing; cluster tooling stays off the sandbox PATH.
- **Attic (`zeiss`) substituter deferred** — the cache isn't set up yet, so the
  image ships no substituter wiring; the first in-container `nix build` is
  uncached. Re-add the URL/key to the image nix.conf when `zeiss` lands.
- nix builds single-user as root (`build-users-group =`, `sandbox = false`) —
  the VM is the boundary; nixosTests get isolation from the surfaced `/dev/kvm`.
- **Agents from `numtide/llm-agents.nix`, not nixpkgs.** claude-code (and any
  future codex/opencode) come from numtide's daily-updated, cache-prebuilt
  packages (nixpkgs lagged 2.1.148 vs numtide 2.1.168 at wiring). Added as a
  flake input (no `follows` — their cache only hits against their pinned
  nixpkgs); scoped to this image (passed as the `claude-code` arg), NOT a global
  overlay override. The build host / CI needs `cache.numtide.com` as a
  substituter (key in the package header) — build-host only, never a sandbox
  egress allowance.
- **Claude freshness = republish cadence, NOT runtime self-update.** The image
  is baked, the self-updater is disabled (`DISABLE_AUTOUPDATER=1` + read-only
  store), and currency comes from a CI job that bumps the input and re-pushes
  `:latest` (cheap via numtide's cache). That CI job is **documented-intent, not
  built** (CI is deferred); until it exists the Phase 3 wrapper can carry the
  cadence (see Phase 3). Runtime update is rejected here: it
  needs egress Phase 5 forbids and would mutate the toolchain mid-session,
  losing image-digest ↔ claude-version auditability. The lockdown-respecting
  runtime path (mirror to creil, pull at session start) is reserved for the
  *persistent* workstation track, not these ephemeral sessions.

Original spec:


1. **`devcontainer.json` in the repo root.** Pin the custom image (Phase 2.2)
   from `creil`. Set `"runArgs": ["--device=/dev/kvm"]`. Keep `postCreate`
   minimal. **Avoid devcontainer "features"** (they apt-install at build time —
   the heavyweight default-image complaint) — bake everything into the Nix
   image instead.
2. **Custom dev image, built with Nix.** `dockerTools.streamLayeredImage` /
   `nix2container`, minimal contents: Nix (flakes) + this flake's dev shell +
   `kubectl`, `git`, `claude-code`, `ripgrep`/`jq`, `alejandra`/`treefmt`.
   **nixpkgs over `npm install`** ([[feedback_nixpkgs_over_npm]]). Wire the
   **Attic substituter (`zeiss`)** so in-container `nix build`/`nix develop`
   hit the cache (this is what made cc-sandbox's hand-rolled `nix copy` dev-
   shell-over-SSH unnecessary). Build as a flake package; push to `creil` via
   standard skopeo / `nix2container` `copyTo` (or a CI job) — **not** a bespoke
   build/push CLI.

## Phase 3 — devpod wiring + operator scripting (item 3)

- **Form: home-manager wrappers on the operator's workstation only** — NOT in
  the VM/container image. This keeps `devpod`/`kubectl`/`virtctl` and the
  orchestration **off the PATH inside the sandbox**, so an agent can't see
  devpod, recursively spawn sandboxes, or reach the cluster. Directly answers
  the operator's stated concern.
- **NOT a top-level repo Justfile for the orchestration** — agents read the
  repo, so a Justfile that drives devpod is discoverable and defeats the
  lockdown intent. (A repo Justfile/`just check` for *in-sandbox* dev tasks is
  a separate, fine thing.)
- Concretely: a `home/modules/dev-machine.nix` (or extend
  `home/modules/kube.nix`) with `writeShellApplication` wrappers —
  `dev-machine up <repo>` / `down` / `ssh` / `list` — thin over standard
  `devpod` + `kubectl`/`virtctl`. This is cc-sandbox's *good* part (the
  init/up/down/ssh/list ergonomics) without the 1100 lines of bespoke Python,
  OIDC, and token-cache code.
- **Start:** wrapper creates the VM + `devpod up --provider ssh --ide none`.
  **Graduate:** thin custom devpod KubeVirt provider (Phase 1 decision) so
  `devpod up`/`down` manages the VM lifecycle.
- **Image-freshness workaround (until CI lands).** The Phase 2 dev image's
  currency is meant to come from a CI republish job that doesn't exist yet. The
  wrapper can carry that cadence in the meantime: have `dev-machine up`
  **build + push the dev image on create by default** (`nix build
  .#dev-machine-dev-image` → `skopeo copy` to creil) before bringing the
  workspace up. It's cheap — claude comes prebuilt from numtide's cache, so it's
  a cache-pull + push, not a real build — and it guarantees each session starts
  on a current claude with no CI dependency. A `--no-rebuild` flag skips it for
  fast iteration. This is build-on-the-operator-workstation, so it stays off the
  sandbox PATH and respects the lockdown. Fold into CI later when CI exists.

## Phase 4 — scoped git push credential (item 4)

The sandbox holds **exactly one** credential, and it is **not** a homelab SSH
key/cert:

- **A Forgejo (`creil`) per-repo deploy key (read-write, single repo)** or a
  fine-grained access token scoped to push to one repo. Blast radius = that one
  repo — it cannot touch other repos or any machine.
- **Branch protection on `creil`** so it can push feature branches but cannot
  merge protected `main` without review. (Push-to-a-branch is the whole job.)
- **Inject** as a k8s Secret → into the VM → into the devcontainer (devpod
  git-credentials injection, or a mounted file the image's git config reads).
  Prefer per-session / short-lived; rotate per session where practical.
- devpod's own SSH into the workspace is its `ProxyCommand` tunnel to the VM —
  the sandbox needs **no homelab SSH credential at all**. The sandbox is
  explicitly **outside** the operator's cert-only end-state
  ([[project_keysjson_certonly_endstate]]): it never holds the operator
  identity.

## Phase 5 — network lockdown (item 5)

- **Reality:** k3s uses **flannel**. Pod / virt-launcher egress SNATs to
  erebonia's management IP (`10.97.11.31`); flannel gives pods **no off-host
  identity** and **no per-pod VLAN** (the bootstrap plan documents this).
- **VLAN-per-VM is declined.** It would need Multus + macvlan/bridge or a
  switch to Calico/Cilium — disproportionate for a single-node homelab dev
  sandbox, and router6 can't distinguish a pod from the host behind the shared
  mgmt IP anyway.
- **The control is `NetworkPolicy`.** k3s ships the kube-router NetworkPolicy
  controller (works with flannel) and supports **egress `ipBlock`**. Put dev
  machines in a **dedicated namespace** with **default-deny egress**, allowing
  only: cluster DNS, `creil` (git/registry), `zeiss` (Attic). Everything else —
  including every other homelab host — is blocked. This is what actually locks
  the sandbox down, and it confines off-host egress too (egress `ipBlock`),
  not just pod-to-pod.
- Use KubeVirt **`masquerade`** interface binding (default) so the VM sits
  behind the virt-launcher pod IP and the namespace `NetworkPolicy` governs its
  egress.
- **Residual / escalation:** `NetworkPolicy` is the boundary. If stronger
  off-host confinement is wanted later, the bootstrap plan's **deliverable E**
  (Calico/Cilium, or erebonia-local nftables on the pod-CIDR path) is the
  documented next step.

## What we drop / lessons carried

- **kata-clh from-source nested kernel** (`runtimes.nix` `nestedKataKernel*`,
  `patchedKataKernelConfig`, `kataClhConfig`) — no longer the dev-machine path.
  `kata-clh` may stay registered as a generic strong-isolation runtime, but the
  custom nested kernel is **retired** for this use case;
  [[project_kata_guest_kernel_no_nested_kvm]] and
  [[project_nixpkgs_kata_qemu_only_clh_override]] become historical here.
- **cc-sandbox bespoke orchestration** — replaced by `devcontainer.json` +
  devpod + thin home-manager wrappers. We keep its *ergonomics* (named
  per-repo workspaces, up/down/ssh/list) and its *Attic-cached dev shell*
  intent (now via the devcontainer image + `zeiss`), and drop its bespoke
  Python/OIDC/cgroup-seccomp code and its hand-rolled `nix copy` dev-shell
  shipping.

## Decisions (resolved 2026-06-07)

1. **VM lifecycle — ephemeral per-session.** A compromised/misbehaving session
   dies with the VM; the environment is reproducible from the devcontainer
   image + Attic cache, so there's nothing worth keeping warm. A warm pool is
   the escalation only if cold-start latency proves painful.
2. **devpod↔KubeVirt wiring — SSH provider to a VM we create.** Proves the full
   chain with zero new code. A thin custom KubeVirt provider is a **follow-up
   iff we need it** (only if the manual lifecycle ergonomics actually bite).
3. **VM image backing — containerDisk.** No durable state worth persisting, and
   it needs no CSI — keeping the iSCSI/democratic-csi dependency entirely on the
   workstation-migration track. DataVolume+CSI is the upgrade only if persistent
   dev machines are ever wanted.
4. **Container runtime in the VM — docker.** It's what devpod's SSH provider
   targets natively (docker socket + `docker` group); rootless isn't needed
   since the VM is the boundary. **podman is the operator's preference as a
   follow-up**, not a blocker for the first cut.
5. **Expose `/dev/kvm` to CI — yes.** Woodpecker CI (workloads-plan Phase 4)
   needs `/dev/kvm` for the VM tests; the dev machine's local KVM is the fast
   inner loop, CI is the durable gate. Same KVM device-plugin / `runc-kvm` path
   serves both. Wire it when CI lands; not a gate on dev machines.
6. **KubeVirt platform ownership — this plan owns the HelmChart.** Proving
   KubeVirt on disposable sandboxes first de-risks the daily-driver edith move;
   `incus-workstation-migration-plan.md` **depends on** the platform landed
   here (its Phase 7.1).
