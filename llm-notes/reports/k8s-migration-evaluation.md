# Kubernetes Migration Evaluation

Date: 2026-05-09

## Question

Would moving from `deployd` (the homegrown containerd wrapper at
`modules/deployd/` + `packages/deployd-{api,helper}/`) to a Kubernetes-based
runtime be a net improvement for this homelab? In particular:

1. Is k8s a good fit for the current dynamic-container workflows that deployd
   serves?
2. Which k8s runtime would be best if we did adopt one?
3. Would k8s replace any of the static microvm.nix / Incus guests?
4. On balance, should we migrate?

## Short answer

**No — stay on the current stack.** The architecture is already a more
considered fit for the stated requirements than k8s would be, and the specific
problems we keep hitting (Kata + nested KVM for cc-sandbox, mutable NixOS in
containers) live below the orchestration layer. K8s does not solve them; it
only adds a control plane on top.

The right next moves are the in-flight ones — finish the
nerdctl→containerd-gRPC migration (`llm-notes/wip/deployd-integration.md`)
and build the iSCSI block-storage add-on for game servers from the existing
spec.

The rest of this document explains why.

## What we currently have

- **Dynamic layer.** `deployd-api` (axum, runs in the `roer` microVM on
  erebonia) → Unix socket over virtiofs → `deployd-helper` (Rust, runs on
  host) → containerd (currently driven via `nerdctl`, transitioning to direct
  gRPC) → kata or runc per-deploy → containers on the `deploy-dmz` bridge,
  fronted by Caddy on the host.

  Hosts: only erebonia today (`hosts/erebonia/default.nix:25`,
  `runtimes.allowed = ["kata" "runc"]`, default kata).

  Active production user: `cc-sandbox` — Claude Code sandboxes built from
  `packages/claude-sandbox-image/`, deployed via `packages/cc-sandbox/`,
  authenticated through OIDC, runs on runc with `/dev/kvm` for nested KVM.

  Specced/planned users: Forgejo Actions runners (saint-arkh hosts the
  daemon today; jobs themselves are kata-isolated), game servers with
  iSCSI-backed suspend/resume, on-demand blogs.

- **Static layer.** ~13 cloud-hypervisor / QEMU microVMs and 2 Incus guests
  (full inventory in `llm-notes/microvm-inventory.md`). All of them are
  long-lived stateful services: Keycloak/Postgres (~100GB), step-ca, nginx +
  oauth2-proxy, Jellyfin (with VAAPI passthrough), Prometheus+Loki+
  Alertmanager+ntfy, Forgejo, Attic, cgit, AdGuard+Unbound. None of them are
  ephemeral.

- **Network model.** `modules/router6/` defines zone-based nftables across
  VLANs. The `deploy-dmz` bridge has a static "only Caddy can reach the
  bridge" rule; deployd-helper has no `CAP_NET_ADMIN` (decision recorded in
  `llm-notes/wip/deployd-integration.md`). All cross-zone access is on the
  router, declaratively.

- **What's been tried and shelved.**
  - **k3s** — explicitly rejected at spec time
    (`llm-notes/specs/dynamic-container-layer.md:47`, "Fights NixOS for
    ownership of networking, storage, and service lifecycle").
  - **Kata for mutable NixOS dev VMs** — closed as "won't do"
    (`llm-notes/done/kata-cloud-hypervisor-migration.md`); kata-agent's
    cgroup ownership is mutually exclusive with systemd PID 1 on cgroup v2.
    Upstream issue #10733 has no path to resolution.
  - **kata-kernel-nested for cc-sandbox** — hung on container launch; we
    added per-deploy runtime selection so cc-sandbox runs under runc with
    direct `/dev/kvm` instead (`llm-notes/done/deployd-runtime-selection-plan.md`).

## What k8s would actually give us

| Capability | Already covered | What k8s adds |
| --- | --- | --- |
| OCI lifecycle (create/start/stop/restart) | deployd-helper | kubelet — same primitive, more daemons |
| Health checks, restart-on-failure | systemd unit `Restart=on-failure` | liveness/readiness probes (genuinely nicer) |
| Image pull from private registry | nerdctl + creil cert in PKI store | image pull secrets — equivalent |
| Kata as a runtime | per-deploy runtime field | `RuntimeClass` (well-supported, equivalent) |
| Ingress | Caddy admin API + helper | Ingress controller — re-implementation |
| Egress filtering | router6 zone rules | NetworkPolicy — re-implementation |
| Secrets | sops-nix + bind mounts | Secret/CSI — different model, same security |
| Persistent storage | bind mounts, planned iSCSI add-on | CSI drivers — useful |
| Multi-host scheduling | not needed | actually new |
| Auto-scaling | not needed | actually new |
| Declarative desired state with controllers | persistent-flag replay | actually new (modest) |
| Multi-tenant RBAC | OIDC group claim on deployd-api | actually new (not currently needed) |
| Auditability | append-only audit log on host | k8s audit log — equivalent |

The genuinely-new capabilities are: multi-host scheduling, autoscaling, CSI
storage drivers, and richer RBAC. Of those, only CSI drivers are even
adjacent to a current need (the iSCSI add-on), and the spec'd add-on already
gives us what we want with less code than deploying a CSI stack.

## What k8s would cost us

1. **CNI vs. router6 collision.** This is the single biggest issue.
   Calico/Cilium/flannel each want to own iptables/nftables tables, ipsets,
   and policy routing on the host. The current model — declarative
   nftables zones in `modules/router6/`, a single static "only Caddy"
   rule for `deploy-dmz`, no dynamic kernel-level mutations from deployd —
   would have to be replaced. We would either (a) accept the CNI as the new
   source of truth and move zones into `NetworkPolicy`, losing the unified
   router model that runs the rest of the network, or (b) try to compose
   them and end up debugging two firewalls at once.

2. **Two truths for state.** NixOS describes the host declaratively; k8s
   describes workloads declaratively but stores them in etcd. Drift between
   them becomes a real operational problem. Today everything that survives
   a reboot is in either NixOS evaluation or `state.json` (which is replayed
   via the same NixOS-defined service).

3. **Operational footprint.** Even k3s is ~500MB–1GB resident (apiserver +
   etcd or kine + controller-manager + scheduler + kubelet + CNI + kube-proxy)
   plus ongoing maintenance. The current dynamic stack on erebonia is two
   Rust binaries (~2k LOC of helper+api) + containerd + Caddy. Several static
   guests run in 256–512MB.

4. **Loses the cc-sandbox security story.** cc-sandbox runs untrusted Claude
   under runc with explicit `/dev/kvm` passthrough; the device allowlist,
   seccomp profile, and per-user volume namespacing are all in
   `packages/deployd-helper/src/validation.rs` and audited via the helper's
   append-only log. Recreating this in k8s requires a privileged Pod (or
   `RuntimeClass=runc` + `securityContext` + custom `PodSecurityPolicy` /
   Pod Security Admission profile) — strictly more pieces, not fewer, and
   the validation now lives in admission webhooks rather than a small Rust
   crate we wrote and can read in one sitting.

5. **Doesn't solve the actual recurring problems.**
   - The Kata + nested-KVM problem (cc-sandbox) was a Kata-kernel issue,
     not an orchestration issue. K8s + kata-runtime hits the same wall.
   - The mutable-NixOS-in-Kata problem is a fundamental Kata cgroup
     ownership incompatibility with systemd PID 1. K8s + kata-runtime hits
     the same wall.
   - The nerdctl/CNI fragility (`llm-notes/wip/deployd-integration.md`
     "post-D0 finding") is being addressed by direct containerd gRPC. K8s
     would replace this with kubelet, which uses CRI/containerd under the
     hood — we'd be trading one wrapper for a much larger one.

6. **Game-server suspend/resume regresses.** The iSCSI add-on
   (`llm-notes/specs/dynamic-container-layer.md:412`) takes advantage of
   Kata's clean block-device unmount on shutdown for atomic NAS snapshots.
   StatefulSets do not have native suspend/resume. We would have to write
   a CRD + operator that ultimately does the same thing the existing
   `Suspend` / `Resume` helper commands do — but on top of k8s rather than
   on top of systemd. Net code increase, not decrease.

## If we did adopt k8s, which runtime?

For completeness, the realistic options:

- **`services.kubernetes.*` (kubeadm-style, NixOS module).** Most NixOS-
  native; module exists in nixpkgs. Operationally heaviest. Best for someone
  who wants kubernetes-the-protocol expressed as Nix.
- **k3s (`services.k3s`).** Most popular in the NixOS homelab world; bundles
  flannel+CoreDNS+ServiceLB+Traefik (most of which we'd disable to avoid
  fighting our existing stack). Was already rejected in the spec.
- **k0s.** Similar profile to k3s; smaller community, less NixOS support.
- **microk8s.** Snap-oriented; poor NixOS fit.

If forced to pick, the answer is **`services.kubernetes.*`** with a
deliberately minimal component set (Calico in policy-only mode, no built-in
ingress, no built-in load balancer, runtime class for kata, runtime class
for runc-with-/dev/kvm). But "best" here is "least bad" — none of them are
better than what we have for our actual workload mix.

## Could k8s replace any static microvm guests?

In principle, several of the deployed workloads could run as Pods. Going
through the inventory honestly:

| Guest | Could it be a Pod? | Should it? |
| --- | --- | --- |
| phantasma (Unbound + AdGuard + oauth2-proxy + nginx) | yes | no — DNS is foundational; one less moving part on the router VM is the whole point |
| messeldam (Keycloak + Postgres ~100GB) | technically | no — running a 100GB Postgres on k8s has its own operations story; the microVM is simpler |
| basel (step-ca CA root keys) | yes | **no** — putting CA root material in `Secret` resources is a regression vs. sops-nix + microVM isolation |
| langport (nginx + oauth2-proxy + WireGuard) | partially | no — WireGuard wants raw networking; nginx is fronting the entire homelab |
| oracion (Jellyfin + Intel VAAPI passthrough) | yes | marginal — VAAPI in k8s is doable via device plugins, but the microVM does it with one nix line |
| tharbad (Prometheus, Loki, Alertmanager, ntfy) | yes (kube-prometheus-stack is the canonical case) | not worth it for one-stack; this is also exactly where you'd start if you ever do migrate |
| creil (Forgejo + container registry) | yes | no — its registry is the supply for cc-sandbox/CI; tight failure-mode coupling with k8s is the wrong direction |
| saint-arkh (Forgejo runner daemon) | yes | no — daemon is long-lived; the *jobs it spawns* are already containers under deployd |
| ardent (Attic, large Nix store) | technically | no — co-locates with NAS storage |
| monrain (cgit + bare git repos) | yes | no benefit |
| edith / trista (dev environments) | no | these need full mutable NixOS — Incus is correct |
| altair / longlai (Headscale + subnet router) | partial | no — needs raw networking and is small |

**Net answer: nothing in the current static fleet is a good candidate.**
Every guest is either (a) requires raw networking / device passthrough that
weakens with Pod abstractions, or (b) is already sized and isolated correctly
as a microVM, or (c) holds key material that does not belong in a shared
control plane.

If we ever did migrate one thing, the kube-prometheus-stack on tharbad is the
least-risky candidate — but doing it for one stack is strictly worse than
the current Nix-managed setup.

## Recommendation

**Stay.** Specifically:

1. **Finish the in-flight deployd work.** The containerd-gRPC migration in
   `llm-notes/wip/deployd-integration.md` removes the actual operational
   pain point (nerdctl/ctr/CNI shell-out fragility) without adding a control
   plane. That's the win we've been looking for.

2. **Build the iSCSI add-on for game servers.** The spec
   (`llm-notes/specs/dynamic-container-layer.md:412`) gives us suspend/resume
   with NAS-side snapshots in a way that's strictly better than what k8s
   StatefulSets do out of the box. It's also a small amount of code — Unix
   socket commands `AttachVolume`/`DetachVolume`/`Suspend`/`Resume` plus
   storage-pool allowlist in the helper.

3. **Accept runc as the answer for nested-KVM workloads.** Already done for
   cc-sandbox. Kata stays for workloads where strong isolation > nested-virt
   performance. Kata-kernel-nested has been deleted; that's the right call.

4. **Keep the mutable-NixOS-dev-VM problem on Incus.** edith (calvard) and
   trista (erebonia) cover this. It's orthogonal to deployd and to k8s.

## When to revisit

Migrating to k8s makes sense if any of these become true:

- Dynamic workloads need to schedule across **3+ hosts** with capacity
  awareness — not just "deployd on erebonia + deployd on calvard."
- We start hosting **multi-tenant** workloads (friends running their own
  game servers, shared CI for outside contributors) where per-namespace
  RBAC and ResourceQuotas pay for themselves.
- The static fleet grows past the point where individual microVMs are
  manageable, and we want a unified scheduler for **both** static and
  dynamic — not just dynamic.

None of these are true today, none of them are on the roadmap, and none of
them are forcing functions. The recurring pain we've been feeling — Kata
weirdness, nerdctl fragility — is being addressed at the right layer
(runtime choice and direct containerd gRPC), not by adopting an
orchestrator.
