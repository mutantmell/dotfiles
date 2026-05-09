# Kubernetes Migration Evaluation

Date: 2026-05-09 (revised — fresh-eyes pass)

## Question

Would moving the dynamic-container layer (today: `deployd` +
`packages/deployd-{api,helper}/`, single-host on erebonia) to a
Kubernetes-based runtime be a net improvement?

Sub-questions:

1. Is k8s a good fit for the workload classes deployd serves (blogs,
   CI runners, Claude Code sandboxes, game servers)?
2. Which k8s distribution and runtime would best fit this homelab?
3. Could k8s replace any of the static microvm.nix / Incus guests?
4. On balance, migrate or stay?

## Approach

This pass deliberately re-derives the answer rather than leaning on the
prior decisions in `llm-notes/specs/dynamic-container-layer.md` (which
rejected **k3s specifically**, not k8s broadly) and
`llm-notes/done/kata-cloud-hypervisor-migration.md` (which is about
mutable-NixOS-in-kata, not orchestration). Those documents are evidence
of past reasoning, not authority on this question.

## What "Kubernetes" actually means here

It's important to disentangle three different things often called "k8s":

- **The k8s API** — Pod / Deployment / StatefulSet / Job / CRD,
  reconciliation loops, RBAC, audit. Distribution-agnostic.
- **kubelet + CRI + containerd** — the per-node agent that drives
  containerd (and therefore kata-shim-v2) on behalf of the API. This is
  the same path the kata-containers project tests against first.
- **The bundled distribution** — k3s, k0s, RKE2, microk8s, kubeadm. Each
  comes with default choices for ingress, load-balancer, CNI, storage
  class. **The earlier rejection of k3s was mostly about k3s's defaults**
  (Traefik vs. our declared Caddy, ServiceLB vs. our nftables, flannel
  re-managing host firewall) — not about the underlying API.

A NixOS-native k8s build via `services.kubernetes.*` (or k0s with most
defaults disabled) is a meaningfully different proposition from k3s with
its batteries included.

## Honest case FOR migration

### 1. Kata is genuinely better-supported via kubelet than via nerdctl

Most of the integration friction we've hit (nerdctl prepending a
namespace prefix to CNI container IDs; rootful/rootless confusion when
sudo'ing nerdctl; ctr-inspect parsing; CNI state file `\r\n`) is
specifically because nerdctl is a Docker-compat CLI bolted onto
containerd, not because containerd or kata are difficult. The kata
project's reference integration is **kubelet → CRI → containerd → kata
shim**. Bug fixes ship for that path first.

Caveat: the in-flight containerd-gRPC migration in
`llm-notes/wip/deployd-integration.md` also gets us off nerdctl. So this
is a "k8s gets it for free" point, not a "only k8s solves it" point.

### 2. The operator ecosystem is unusually well-matched to the named workloads

- **Blog**: Deployment + Service + Ingress, with Flux/ArgoCD watching
  the content repo for image updates. This is the canonical k8s pattern
  and noticeably less code than wiring deployd to a webhook.
- **CI runners**: actions-runner-controller (or the Forgejo equivalent)
  autoscales runner pods on queue depth, runs each job in a fresh pod
  with its own `RuntimeClass`. Strictly better than running a long-lived
  runner daemon (saint-arkh) that spawns local jobs.
- **Claude sandboxes**: still a Pod with a `RuntimeClass` and an OIDC
  flow on top. Code-volume comparable to the current deployd-api, no
  obvious win, no obvious loss.
- **Game servers**: StatefulSet + PVC + VolumeSnapshot covers the
  "weeks-long, survives reboot, snapshot the world" use case. Agones
  exists for session-allocation-style fleets but is overkill for the
  stated requirement.

### 3. CSI is a proper home for the iSCSI block-storage feature

The iSCSI suspend/resume add-on in
`llm-notes/specs/dynamic-container-layer.md` is essentially a small,
custom storage controller. With k8s + a CSI driver
(`democratic-csi` against TrueNAS, or `openebs-mayastor`,
or `longhorn`), you get dynamic provisioning, snapshot CRDs, and clone
support out of the box. Snapshots become first-class kubernetes
resources rather than a `state.json` field.

### 4. Multi-runtime via `RuntimeClass` is the cleaner expression

The per-deploy `runtime: "kata" | "runc"` field maps directly onto k8s
`RuntimeClassName`. We can also add a custom `runc-kvm`
`RuntimeClass` (paired with the kvm-device-plugin) for the cc-sandbox
nested-KVM case without special-casing it in our own code.

### 5. Multi-host and KubeVirt as a long-term direction

If the homelab ever runs dynamic workloads across erebonia *and*
calvard, k8s schedules across them natively; deployd would need a
second instance with a manual placement decision per workload.
**KubeVirt** runs full VMs as `VirtualMachine` CRDs alongside Pods —
unmodified NixOS guests, libvirt/QEMU underneath, live migration
across nodes, snapshots via CSI. This wouldn't replace microvm.nix
tomorrow, but it's a credible 5-year direction for unifying VM and
container management under one control plane.

## Honest case AGAINST migration

### 1. CNI ↔ router6 integration is real ongoing engineering

Every CNI either (a) leaves host networking alone and provides only
pod-to-pod policy, or (b) takes ownership of large pieces of host
firewall/routing. Cilium with `hostFirewall=false` and policy-only
mode, or Calico in policy-only mode, are the "leave host alone"
choices. Either is workable but introduces a second policy surface
that needs to be reasoned about alongside `modules/router6/`.

The cluster network ends up being its own zone (vDMZ-ish); router6
governs inter-VLAN traffic; CNI governs intra-cluster. That's a
clean-enough split, but it's a real architectural change and a
permanent operational complexity tax (two firewalls to debug, not one).

### 2. Two sources of truth for workload state

Today, every workload is described in either NixOS evaluation or
deployd's `state.json` (replayed by a NixOS-defined service). With k8s,
manifests live in etcd. Reasonable mitigations:

- Store manifests in this flake, apply via Flux/ArgoCD on commit (most
  Nix-friendly).
- Generate manifests from Nix expressions and apply via `kubectl
  apply -k` from a NixOS systemd service.

Either works, but the "single declarative source" property of the
current setup is genuinely lost.

### 3. Operational footprint at small scale

Even a stripped-down k8s control plane (apiserver + etcd or
kine + controller-manager + scheduler + kubelet + CNI) is
500MB–1GB resident plus daemons-to-monitor. On a single dynamic-layer
host this is a real cost. Several static microVM guests run in 256MB.
The cost gets cheaper per-workload as the workload count grows; it's
unfavorable at today's scale.

### 4. Auth and developer-tooling surface area

deployd's auth model is a single OIDC bearer token with a group claim,
checked once per request. K8s adds RBAC, ServiceAccounts, and (for
human users) `kubectl` context management on top of the same OIDC.
For machine callers (CI deploying a blog), ServiceAccount tokens are
fine. For human callers (cc-sandbox CLI today), the auth code stays
roughly the same size but talks to a much larger API.

### 5. Custom code investment is genuinely small today

deployd is ~2k LOC of Rust (helper + api combined), with the trust
boundary in one file (`packages/deployd-helper/src/validation.rs`) and
the privileged operations in one shell script
(`modules/deployd/default.nix:39`). It's small enough to read in a
sitting and audit per-change. K8s replaces this with kubelet (~500k
LOC) + CRI runtime + admission controllers + RBAC policy. Same security
properties, much larger surface.

### 6. The static-fleet migration question is unattractive

If migration is dynamic-layer-only, k8s is justified or not on its own
merits. If it's "and the static fleet too via KubeVirt," the cost
balloons and the upside is mostly "live migration we don't need" and
"unified control plane that costs us NixOS-native module declarations
like `services.keycloak.enable = true`."

## Per-workload assessment

| Workload | Current | K8s equivalent | Honest verdict |
| --- | --- | --- | --- |
| Blog (on-demand redeploy) | not built yet | Deployment + Flux watching content repo | k8s wins on idiom |
| CI runners (Forgejo Actions) | saint-arkh microVM hosts daemon; jobs are isolated | runner controller + per-job kata Pods | k8s wins, especially at scale |
| Claude sandboxes | cc-sandbox CLI → deployd-api → runc Pod with /dev/kvm | OIDC client → k8s API → Pod with `RuntimeClass=runc-kvm` + kvm-device-plugin | roughly equivalent |
| Game servers (long-lived, weekly play) | spec'd but unbuilt; iSCSI + suspend/resume | StatefulSet + PVC + VolumeSnapshot | k8s wins on storage primitives |

So: of the four named workload classes, **two are genuinely better
served by k8s + ecosystem (CI runners, game-server storage), one is
roughly a wash (Claude sandboxes), one isn't built yet either way (blog,
where k8s is more idiomatic but neither is hard)**.

## If migrating, what runtime?

The right answer is **not k3s** — its bundled defaults (Traefik+ServiceLB
+flannel+local-path) are exactly the layers we'd disable, leaving us
fighting opinionated removals. Better:

- **`services.kubernetes.*` (kubeadm-style, NixOS module)** — most
  NixOS-native; the control plane is declared in the same flake as
  everything else. Heaviest operationally but most consistent with the
  rest of the stack.
- **k0s** — single binary, sane minimal defaults, available as a
  package in nixpkgs. Reasonable second choice.

Component picks for either:

- **CNI: Cilium** with `kubeProxyReplacement=true`,
  `hostFirewall=false`, eBPF datapath. Plays well with existing
  host nftables and gives us NetworkPolicy as the pod-policy surface.
  Calico in policy-only mode is a simpler alternative.
- **Container runtime: containerd** (only realistic choice with kata).
- **Runtimes**:
  - `RuntimeClass: kata-qemu` — default for new isolated workloads
  - `RuntimeClass: runc` — for general-purpose
  - `RuntimeClass: runc-kvm` — runc with kvm-device-plugin for
    cc-sandbox-style nested-KVM
- **CSI: democratic-csi** against the NAS (zfs-generic-iscsi or
  zfs-generic-nfs depending on workload). Gives us VolumeSnapshot for
  the game-server use case.
- **Ingress: keep Caddy on the host**, point at NodePort services. Don't
  introduce a second ingress controller; we already declare Caddy.
- **GitOps: Flux v2** reading manifests from creil. Lighter than
  ArgoCD; closer to "apply this directory" semantics.

## Could k8s replace static microvm guests?

Going through the inventory honestly:

- **Could run as a Pod**: phantasma (DNS/AdGuard), langport (nginx),
  oracion (Jellyfin, with VAAPI device plugin), tharbad (kube-prometheus-
  stack is the canonical case), creil (Forgejo), monrain (cgit), ardent
  (Attic), saint-arkh (the CI controller, not the runner daemon).
- **Could run as a KubeVirt VM**: messeldam (Keycloak+~100GB Postgres),
  altair (Headscale), longlai (subnet router) — same as today's microVM,
  different control plane.
- **Should not move**: basel (CA root keys are worse off in `Secret`
  resources than in microVM + sops-nix), the foundational guests on
  thebeyond, edith/trista (mutable NixOS dev environments are correct
  on Incus).

**Of these, only the kube-prometheus-stack on tharbad is a clearly
better fit on k8s.** Everything else is "could move, no real reason
to." A static-fleet migration is busywork unless we're committing to
k8s as the foundational platform — which is a much bigger decision
than the dynamic-layer question.

## On-balance recommendation

This is closer than the previous pass made it sound. Two scenarios:

### Scenario A — extend deployd

**When this is right:**
- The homelab stays roughly the size it is now (one host running
  dynamic workloads).
- The operator prefers extending small audit-able Rust code over
  operating a kubelet+CNI+CSI stack.
- The named pain points (kata friction via nerdctl, missing
  iSCSI/snapshot story) are addressable in deployd in 3–6 months of
  work that is mostly already specced.

**Cost:** the operator owns the storage controller, the auth flow, and
the network management forever. Each new workload type adds custom
code.

### Scenario B — move the dynamic layer to k8s

**When this is right:**
- The homelab is a multi-year direction that wants to grow into
  multi-host scheduling, CI runner autoscaling, and possibly KubeVirt
  for new VM-shaped workloads.
- The operator wants to invest in k8s skills as a platform.
- The CSI / NetworkPolicy / RuntimeClass model maps cleanly onto the
  use cases (it does).

**Shape:** k0s or `services.kubernetes.*` on erebonia (single node to
start, calvard joinable later), Cilium policy-only, democratic-csi
against the NAS, Flux for manifests, Caddy retained on host, deployd
deprecated and removed once the four workload classes are migrated.

**Cost:** 6–12 months of careful migration work, ongoing
operational complexity tax, design work to keep router6 zones and
CNI policy in sync.

### My lean

If forced to pick today, I lean toward **Scenario A (stay)** for one
specific reason: the highest-leverage k8s wins (CI runner autoscaling,
CSI volume snapshots) are real but small in absolute terms at this
scale, and the in-flight containerd-gRPC migration removes the most
acute deployd pain point. The k8s investment doesn't pay for itself
until the homelab has more workloads than we can hand-roll one at a
time.

But this lean is genuinely 60/40, not the 90/10 the previous pass
implied. Scenario B is a defensible choice if the operator wants k8s
as a long-term platform direction. The previous "the spec already
rejected k3s" framing over-counted that decision: it was a different
question (k3s the distribution) at a different time.

## What this pass changes vs. the previous report

- Acknowledges that **k8s ≠ k3s**; the spec's k3s rejection doesn't
  generalize.
- Credits **kubelet + containerd + kata** as the genuinely-better
  integration path for the kata friction we've hit (vs. previously
  framing it as orthogonal).
- Credits **operator-ecosystem fit** for CI runners and game-server
  storage, which the previous pass dismissed too quickly.
- Distinguishes **`services.kubernetes.*` / k0s** from k3s as
  meaningfully different choices.
- Reframes the recommendation as **60/40 stay** rather than "obvious
  no" — Scenario B is a real option if the operator wants the
  platform investment.
