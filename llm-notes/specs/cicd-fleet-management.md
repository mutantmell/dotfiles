# NixOS Homelab Pipeline and Fleet Activation: Specification

**Status:** Active design spec. Workload integration is framed around k3s/Flux;
re-ground the concrete dynamic-manifest path in
`llm-notes/wip/k3s-cluster-workloads-plan.md` before implementation.

> **Implementation note (2026-06-16).** The concrete CI topology is the hybrid
> described in `llm-notes/plans/cicd-fleet-activation-plan.md`: `saint-arkh`
> remains a control-plane-only Woodpecker server microVM, while build execution
> happens through Woodpecker's Kubernetes backend on erebonia k3s. The server
> microVM is deliberate: it keeps CI identity, webhooks, UI, config service, and
> SQLite state reachable when k3s/Flux is degraded. Host-level Woodpecker agents,
> standalone containerd/Kata runners, and host-agent secret injection are no
> longer part of the target design.

## Overview

This system is a paper-thin connective layer between a build system and `nixos-rebuild`. It does not provision hosts, manage secrets in the Nix store, or coordinate fleet-wide state as a central authority. It receives a signal that CI has produced a verified, signed closure, and activates it safely on hosts that cannot or should not build themselves.

The system has two halves that are inseparable in practice:

- **The CI pipeline** — builds NixOS closures, signs them, pushes them to the binary cache, and publishes build events to the event bus
- **The fleet activation layer** — receives build events, downloads and verifies closures, activates them via `nixos-rebuild`, and publishes results back to the event bus

Neither half works without the other. This document specifies both as a single system.

The event bus is NATS with JetStream, deployed as a three-node Raft cluster across the homelab's three infrastructure hosts: the NAS (which also hosts Attic), erebonia (the k3s/KubeVirt host that schedules CI build pods), and calvard. Attic and the CI signing key being on separate machines means the dual-signature isolation property holds by natural infrastructure layout rather than requiring deliberate separation.

---

## 1. Scope

This system is the **complete deployment pipeline** for a NixOS homelab treated as a unified system rather than a collection of independent machines. It is responsible for:

> Building verified NixOS system closures from a git repository, distributing them to a binary cache, and activating them safely and efficiently across a fleet of heterogeneous hosts.

It is explicitly **not** responsible for:

- Initial host provisioning (handled by nixos-anywhere + disko)
- Managing secrets (handled by sops-nix and passage)
- Defining NixOS configurations (handled by the user's flake)
- Deploying network-isolated or remote hosts (handled by deploy-rs — see Section 10)
- Dynamic workload manifests (handled by the k3s/Flux layer — see Section 9)

The minimum viable use case that motivates this system is a homelab containing **at least one host that is network infrastructure** — typically a router or gateway — where:

- The host is too underpowered to build its own NixOS closure
- The host cannot be taken offline to update without disrupting other hosts
- The host cannot accept inbound SSH connections without compromising its security posture
- The host must remain power-efficient, ruling out polling-based update mechanisms

Once this infrastructure exists for the router case, all other hosts in the homelab naturally adopt the same deployment model at negligible additional cost.

---

## 2. Design Goals

### 2.1 Primary Goals

**Event-driven delivery.** Hosts activate updates in response to events published by CI, not by polling. This allows hosts to remain in low-power idle states between deployments and eliminates unnecessary network traffic and wakelock overhead.

**Outbound-only connections from hosts.** All hosts initiate connections to the NATS cluster; no host accepts inbound connections for deployment purposes. This is a hard requirement for router/gateway hosts and is applied uniformly across the fleet for consistency and security.

**Network-safe activation.** The full system closure is downloaded and verified before activation begins. For hosts that are network infrastructure, this ensures that the network path to the binary cache is not severed mid-download during activation.

**Secrets model.** Runtime secrets (NKey credentials, NATS TLS private keys, Attic tokens, Woodpecker OAuth/backend credentials, Kubernetes build-namespace secrets) are managed with sops-nix and decrypted into tmpfs at activation or materialized into scoped Kubernetes Secrets through the cluster desired-state path — they never touch the Nix store. Secrets that need to be accessible outside of a NixOS activation context (operator credentials, backup keys, things needed from a live disk) use passage. The boundary is: sops-nix for service secrets, passage for operator secrets.

**Cryptographically enforced build trust.** A malicious deployment requires simultaneously compromising both the CI pipeline and the binary cache server — two independent systems with separate credentials and attack surfaces. A compromised NATS cluster can cause spurious or delayed deployments but cannot cause a host to run attacker-controlled code. A compromised Attic server alone cannot inject malicious builds because it cannot forge the CI signature. A compromised CI pipeline alone cannot inject malicious builds because it cannot forge the Attic signature. Trust is enforced by Nix's store signing model with dual-signature verification: every store path must carry valid signatures from both the CI signing key and the Attic signing key before activation proceeds.

**Staged activation with automatic revert.** Hosts can receive a test activation that is automatically reverted after a configurable window unless a production event is received. PR builds trigger test activations; merges to main trigger permanent activations. This provides a meaningful safety gate without requiring a separate staging environment.

**Low operational overhead.** The system depends on three pieces of infrastructure — a NATS JetStream cluster, a binary cache (Attic), and a CI server (Woodpecker). All three are low-resource NixOS services declared in the flake, updated by the same system they support.

### 2.2 Secondary Goals

**Events describe facts, not commands.** The event bus is a record of things that have happened — "CI successfully built and signed closure X from commit Y" — not a channel for directed actions. Coordinators are autonomous agents that subscribe to facts relevant to them and decide independently how to respond according to their local policy. This makes the event stream auditable, self-describing, and extensible: new subscribers can be added without changing what CI publishes.

**Per-host local policy.** Each host enforces its own deployment policy — which build events to respond to, what source ref constitutes a production build versus a test build, how long a test window lasts. Policy is declared in the host's NixOS configuration.

**Declarative deployment ordering via the common module.** Deployment ordering (which host waits for which before activating) is declared in the flake's common module as a topology map, shared across all host configurations. Each host is standalone and can be deployed in isolation; the topology map governs sequencing when deploying the full fleet.

**Fleet visibility without central control.** Hosts publish activation facts back to the NATS cluster. Any subscriber can consume them without being known to the system in advance — a monitoring dashboard, an audit log, or a future central coordinator.

**Composability with existing NixOS tooling.** The system introduces no new abstractions for secrets, configuration evaluation, or binary cache hosting. It integrates with sops-nix, Attic, microvm.nix, step-ca, and standard NixOS flakes without modification.

### 2.3 Explicit Non-Goals

- Ordered multi-host rollouts beyond what `dependsOnActivation` provides
- Coordinated fleet-wide rollback
- Dynamic secret rotation outside of normal config deployments
- Incremental adoption without prerequisite infrastructure
- Support for non-NixOS hosts on the NATS path
- A central coordinator service with fleet-wide orchestration logic

### 2.4 Potential Future Directions

A central coordinator is explicitly not built here, but nothing in this design is contrary to building one on top:

- The `activations.<hostname>` subject already provides per-host activation state a coordinator would need
- NATS subjects accommodate a coordinator as an additional publisher without changes to the per-host coordinator
- Per-host policy options can be extended to support coordinator-driven sequencing

What a central coordinator would add: consensus-based fleet-wide rollback, health-gate promotion (only promote if N% of test hosts succeeded), and finer-grained canary sequencing. The right time to build it is when the per-host model demonstrably fails to meet a real need.

---

## 3. Survey of Alternatives

### 3.1 Deployment tool alternatives

**`system.autoUpgrade`** — Timer-based polling prevents CPU idle states; evaluates and builds on the target host (underpowered hosts OOM); no staged activation.

**comin** — Polls a git repo on a configurable interval; prevents CPU idle states; no event-driven delivery; no promotion gate. Correct choice for homelabs without power sensitivity or network topology constraints. Closest existing tool to this design.

**deploy-rs** — Requires inbound SSH; push model; no power efficiency consideration. Used in this homelab for isolated/remote hosts where the NATS model is inappropriate — see Section 10.

**Colmena** — Requires inbound SSH; centralised topology knowledge; no staged activation.

**Cachix Deploy** — Hosted commercial service; closed-source agent; no network-safe activation; no staged test-and-revert.

**numtide/nits and numtide/nix-fleet** — The closest projects in the ecosystem to this design: pull-based, NATS-based, outbound-only agents. Not adopted because: nits/nix-fleet are pre-1.0 with actively changing architecture; the binary cache is built on NATS KV/Object stores rather than a dedicated cache (losing Attic's deduplication, retention policies, and signing model); nix-fleet uses a centralised coordinator model contrary to this design's distributed per-host policy approach. The blog posts by nits author Brian McGee on NATS permission modelling and NKey-per-host derivation from SSH host keys are directly useful reference material.

| Property                       | autoUpgrade | comin | deploy-rs | This system |
| ------------------------------ | ----------- | ----- | --------- | ----------- |
| No local build required        | ✅          | ✅    | ✅        | ✅          |
| No inbound SSH                 | ✅          | ✅    | ❌        | ✅          |
| Event-driven (no polling)      | ❌          | ❌    | ✅        | ✅          |
| Network-safe activation        | ❌          | ❌    | ❌        | ✅          |
| Staged test + revert           | ❌          | ⚠️    | ❌        | ✅          |
| Untrusted transport model      | N/A         | N/A   | N/A       | ✅          |
| No prerequisite infrastructure | ✅          | ✅    | ✅        | ❌          |

### 3.2 CI system alternatives

**Forgejo Actions** — Built-in to Forgejo, GitHub Actions-compatible YAML syntax, good community library of actions. No native Attic integration (requires manual CLI steps). Runner isolation requires either configuring Docker's default runtime globally to Kata or wrapping the runner in a microVM. Simpler operational model than Woodpecker at the cost of the features below.

**Woodpecker CI** — Chosen. Separate CI service with native Forgejo integration. Has a dedicated Attic plugin (`woodpecker-plugin-nix-attic`). A Woodpecker External Configuration Service generates pipelines dynamically from flake outputs — directly valuable given the large number of build targets. The `woodpecker-flake-pipeliner` project by pinpox is the candidate implementation to evaluate; if unavailable, a replacement is small and bounded. With the current k3s direction, Woodpecker uses the Kubernetes backend on erebonia instead of host-level Docker/containerd agents. This lets build pods use the cluster's existing RuntimeClass, PSS, NetworkPolicy, and Kyverno controls. In nixpkgs with NixOS modules. Used in production at Codeberg.

**buildbot-nix** — Deepest Nix-native evaluation (parallel flake evaluation via `nix-eval-jobs`, automatic `.#checks` discovery). No native Attic integration. Systemd watcher approach for cache population. Stronger evaluation awareness than Woodpecker but weaker plugin ecosystem. Good reference for Nix-CI patterns.

**Hercules CI** — Best Nix integration in the ecosystem with the effects system. **Does not support Forgejo** — eliminated. Supports only GitHub and GitHub Enterprise.

**Event bus selection note:** MQTT (Mosquitto) was the initial candidate and has the right protocol-level properties. NATS with JetStream was chosen because built-in Raft clustering provides HA as a first-class property, and the three infrastructure hosts provide exactly the right hardware for a three-node cluster.

---

## 4. Architecture

### 4.1 Overview

```
┌──────────────────────────────────────────────────────────────┐
│ Woodpecker CI (saint-arkh microVM on erebonia)                │
│ server + config service; stable CI identity and state         │
│                                                              │
│  1. evaluate flake (config service → pipeline from outputs)  │
│  2. submit per-step pods through Kubernetes backend           │
│     (woodpecker-builds namespace on erebonia k3s)             │
│  3. build pod: nix build .#nixosConfigurations.<host>.system │
│  4. build pod: nix store sign --key-file $CI_KEY --recursive │
│  5. build pod: attic push <cache> <closure>  (Attic on NAS)  │
│  6. publish builds.nixos.<configuration> { facts }           │
└────────────────────────────┬─────────────────────────────────┘
                             │ TLS
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ NATS JetStream Cluster (3-node Raft)                         │
│ One microVM per host: NAS, erebonia, calvard                  │
│ Routes events only — isolated from signing keys              │
└──────┬──────────────────────────────┬────────────────────────┘
       │ TLS (outbound from host)     │ TLS (outbound from host)
       ▼                              ▼
┌─────────────┐              ┌─────────────────┐
│   router    │              │   nas / other   │
│             │              │                 │
│ coordinator │              │  coordinator    │
│  (NixOS     │              │   (NixOS        │
│   module)   │              │    module)      │
│             │              │                 │
│ 1. receive  │              │ 1. receive      │
│ 2. wait for │              │ 2. download     │
│    upstream │              │    closure      │
│ 3. download │              │ 3. verify sigs  │
│    closure  │              │ 4. switch/test  │
│ 4. verify   │              │ 5. pub result   │
│    sigs     │              └─────────────────┘
│ 5. switch   │
│ 6. pub      │
│    result   │
└─────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────────────┐
│ Attic (binary cache, on NAS)                                 │
│ Attic signing key lives here (separate from CI key)          │
│ Server-side signing + CI pre-signing = dual signatures       │
└──────────────────────────────────────────────────────────────┘
```

### 4.2 Trust Model

The system's security model is based on **dual-signature verification**: a malicious deployment requires simultaneously compromising both the CI pipeline and the Attic server.

**How signing works:**

- CI builds closures and signs every store path with a private Ed25519 key before pushing to Attic: `nix store sign --key-file $CI_KEY --recursive ./result`
- Attic adds its own server-side signature when paths are fetched (Attic's managed signing model: the server holds the Attic signing key, not the pusher)
- Paths served by Attic carry two independent signatures: the CI signature and the Attic signature
- The coordinator requires both signatures before activation: `nix store verify --recursive --sigs-needed 2`

**Why this provides genuine isolation:**

A compromised Attic server holds the Attic signing key but cannot forge the CI signing key. A compromised CI pipeline holds the CI signing key but cannot forge the Attic signing key. Both must be compromised simultaneously to inject a malicious build.

**The condition for this property to hold:**

CI execution and Attic must run on separate machines. In this homelab: Attic and its signing key run on the NAS; CI build pods and the CI signing key run on erebonia's k3s cluster. These are separate physical machines. The Woodpecker server microVM coordinates builds but does not need the build signing key; the NATS microVMs on each host are isolated from the host trust boundary and cannot access either signing key.

**High-value targets:**

The erebonia build namespace holds the CI signing key as a scoped Kubernetes Secret for build pods. The NAS holds the Attic signing key. Each alone is insufficient for a malicious deployment. Ordinary Woodpecker build jobs run as Kubernetes pods using the `runsc` RuntimeClass plus PSS Restricted, NetworkPolicy, and Kyverno admission controls. VM-test or `/dev/kvm` jobs require a separate trusted build class or out-of-cluster path and must not inherit the ordinary untrusted-build assumptions.

**Summary of trust tiers:**

| Component                 | Trust level                  | Compromise impact                  |
| ------------------------- | ---------------------------- | ---------------------------------- |
| CI signing key (erebonia build namespace) | Trusted — insufficient alone | Partial: CI-only paths rejected    |
| Attic signing key (NAS)   | Trusted — insufficient alone | Partial: Attic-only paths rejected |
| Both keys simultaneously  | Full trust boundary          | Fleet compromise                   |
| NATS cluster              | Untrusted                    | Deployment disruption only         |
| Network transport         | Untrusted                    | Deployment disruption only         |

---

## 5. Component Specifications

### 5.1 Woodpecker CI Server and Kubernetes Backend

**Responsibility:** Build NixOS closures, sign them, push them to Attic, publish build events to NATS, orchestrate results-gated sequential deployment.

**Deployment:**

Woodpecker server and the config service run together in a single cloud-hypervisor microVM on erebonia (`saint-arkh`). This microVM is control-plane-only: it receives Forgejo webhooks, hosts the UI/API, stores Woodpecker's SQLite state, and runs the localhost-only external config service.

Build execution uses Woodpecker's Kubernetes backend. Each pipeline step becomes a pod in the `woodpecker-builds` namespace on erebonia's k3s cluster. There is no standing host-level `woodpecker-agent` and no standalone Docker/containerd runner path in the target design.

Keeping the server outside k3s is intentional. If k3s, Flux, or cluster ingress is degraded, the CI control plane, job history, webhook receiver, and config service remain available for diagnosis and repair. Running the server as a Flux-managed workload can be revisited later, but it would make the CI control plane depend on the same cluster layer it is meant to test and eventually help repair.

The build namespace carries the untrusted-code boundary: PSS Restricted where compatible, default `runsc` RuntimeClass, NetworkPolicy default-deny with explicit egress, Kyverno admission policies, and scoped Kubernetes Secrets for CI credentials. KVM-capable NixOS VM tests are a separate build class decision, not part of the default untrusted pod profile.

Forgejo is the git forge only — it stores code, triggers Woodpecker webhooks on push/PR/merge, and hosts the container registry. Forgejo's built-in Actions runner infrastructure is not used. Woodpecker connects to Forgejo via an OAuth2 application for authentication and webhook events, and runs its own agents entirely independently.

**Flake pipeline generation:**

With a large number of build targets in the flake, a Woodpecker External Configuration Service eliminates the need to maintain `.woodpecker.yml` files per target and makes the flake the single source of truth for both system configuration and CI pipeline definition. The config service runs on localhost only within the Woodpecker microVM — Woodpecker POSTs to it over loopback, and nothing else can reach it. This localhost-only constraint removes essentially all network attack surface and makes signature verification of incoming requests unnecessary.

The `woodpecker-flake-pipeliner` by pinpox is the candidate implementation to evaluate at implementation time. It is a small Go service based on Woodpecker's official example config service. If it is incompatible with the current Woodpecker version or abandoned, writing a replacement is a bounded task (~200-300 lines) — the External Configuration API itself is stable and officially maintained by Woodpecker upstream. The config service and Woodpecker server share a microVM and lifecycle.

**Agent-readable CI output and PR feedback:**

CI must publish compact, structured check output in addition to normal logs.
For each PR/head SHA, expose:

- `check-summary.json` — machine-readable status, failed check names,
  reproduction commands, failing command snippets, artifact/log URLs, and
  relevant log tails.
- `check-summary.md` — a human-readable PR comment or artifact with the same
  information in review-friendly form.

Agents should not have to scrape entire Forgejo/Woodpecker logs to diagnose
routine failures. Every generated check should map back to one repo-local
reproduction command (`./scripts/run-checks.sh <name>`,
`nix build .#checks.x86_64-linux.<name>`, `agent-preflight-quick`, etc.).

Agent-facing PR integration is specified in
`llm-notes/plans/agent-ci-readonly-woodpecker-plan.md`. The default target is
not a bespoke Forgejo/Woodpecker client: Forgejo status gates PRs, agents use
the normal Forgejo-facing interface for PR state, and read-only Woodpecker
access exposes detailed CI logs plus `check-summary.json`. The older trusted
sticky-comment reporter design is archived at
`llm-notes/done/agent-ci-feedback-loop-plan.md` and remains an optional
hardened path if read-only Woodpecker access is insufficient.

AGit remains an operational fallback until the normal-branch + `tea` workflow
has validated branch namespace restrictions, token scope, token materialization,
and smoke-test behavior.

Lifecycle comments form the human control plane for active agent sessions. The
initial vocabulary should cover:

- `agent: retry checks`
- `agent: fix review comments`
- `agent: rebase`
- `agent: explain failure`
- `agent: run full preflight`
- `agent: ready for review`

Notification can start as polling from the agent tool and later move to
webhook-to-queue delivery if the workflow needs lower latency.

**Flake dependency updates:**

Woodpecker cron jobs run `nix flake update` on a configurable schedule and open a PR against Forgejo. Self-hosted Renovate with the Nix manager enabled is an alternative for more granular per-input update PRs. The scheduled update PR triggers a test build (PR source_ref), which must pass before the PR is merged.

**Event schema:**

CI publishes facts about what was built, not commands directed at specific hosts. The `source_ref` field carries the git ref the closure was built from; coordinators use this to determine their activation mode.

```json
{
  "flake_ref": "gitea:org/infra@abc123def456",
  "nixos_configuration": "router",
  "store_path": "/nix/store/<hash>-nixos-system-router-24.05",
  "source_ref": "refs/heads/main",
  "built_at": "2024-01-15T10:30:00Z",
  "signed_by": ["ci:abc123...", "attic:xyz789..."]
}
```

**NATS subject structure:**

- `builds.nixos.<configuration>` — CI build completion events, one per NixOS configuration
- `activations.<hostname>` — activation facts published by hosts

**PR vs merge model:**

CI publishes all builds to the same subject regardless of source. The coordinator's local policy determines activation mode based on `source_ref`. PR builds trigger `nixos-rebuild test` (auto-revert); merges to main trigger `nixos-rebuild switch`.

**Results-gated sequential deployment:**

Builds run in parallel. Deployment events are published sequentially, gated on each host confirming success before the next event is published. Ordering is determined by the common module topology map (see Section 5.3).

```
build phase (parallel, all hosts via config service from flake outputs):
  [router] [nas] [workstation] [...]

deploy phase (sequential, results-gated, order from common module):
  nats pub builds.nixos.router "$PAYLOAD"
    → nats sub --count 1 activations.router  # wait for success
    → if rolled-back or timeout: abort, alert
  nats pub builds.nixos.nas "$PAYLOAD"
    → nats sub --count 1 activations.nas
    → ...
```

**Build interruption model:**

Because build execution is in k3s pods, a restart of the `saint-arkh` server
microVM should not be treated like a host-agent binary replacement. In-flight
pods may continue or fail depending on Woodpecker's Kubernetes backend behavior
and server availability; a hard restart of erebonia/k3s loses running build
pods. The operational rule is simpler than the old host-agent model: CI jobs are
retriable, and Phase 1 should keep the initial pipeline idempotent with compact
failure summaries so failed jobs can be restarted cleanly.

**Attic integration:**

The `woodpecker-plugin-nix-attic` plugin handles pushing build results to Attic.

**Secrets management for CI:**

Woodpecker OAuth2 credentials and any server/backend credentials live on
`saint-arkh` as sops-nix secrets. Build credentials — the CI signing key, Attic
push token, and NATS CI NKey — are scoped to the `woodpecker-builds` namespace as
Kubernetes Secrets generated from the repo's secret-management path. They are
mounted or injected only into build pods that need them.

Do not store build credentials in Woodpecker's database-backed secrets store,
and do not grant them to the Woodpecker server process unless the server itself
needs them. A Woodpecker admin should not be able to exfiltrate the CI signing
key through the UI; the key should be visible only to the specific build pod
service account and only for the duration/scope required by the pipeline.

**Attic garbage collection:**

Attic's built-in GC runs as a separate process (`atticd --mode garbage-collector`) on a configurable interval. The GC must run as a single instance — it cannot be replicated.

Retention policy must account for the longest plausible time a host might be offline before receiving a build event. A host that was offline when CI published a build event will receive it on NATS reconnect (JetStream `LastPerSubject` retains the most recent event indefinitely), but will then attempt to pre-download the closure from Attic. If Attic has GC'd those paths in the interim, the pre-download fails and the deployment cannot proceed.

Retention is therefore set to cover the maximum expected offline window plus a safety margin:

- **30 days** retention per cache is the baseline — this covers hosts that are powered off for weekends, holidays, or short maintenance windows
- The "last 3 builds per host" minimum is a floor for rollback support, not a ceiling for retention
- If any managed host is expected to be offline for longer than 30 days (e.g., seasonal use), retention should be extended accordingly

```bash
attic cache configure homelab --retention-period '30 days'
```

The coordinator's pre-download failure is detectable and should be published as a result event so the fleet visibility layer can alert on it.

**source_ref pattern verification:**

The `testRefPatterns` configuration in each host's coordinator uses glob matching against the `source_ref` field published by CI. A mismatch between the pattern and Forgejo's actual ref format for PRs would cause a PR build to activate with `nixos-rebuild switch` instead of `nixos-rebuild test` — a permanent activation from an unreviewed branch with no auto-revert. This is a silent failure mode with significant consequences.

Forgejo's PR ref format should be verified against a real PR before the coordinator is deployed. The expected pattern is `refs/pull/*` but Forgejo may use `refs/pull/*/head`, `refs/pull/*/merge`, or similar variants depending on version and configuration. Confirm the exact format and update `testRefPatterns` accordingly before going live.

**Notes:**

- CI must push the **complete closure** to Attic. Use `nix path-info --recursive` to enumerate all paths.
- Build CI secrets (signing key, Attic token, NATS NKey) are scoped Kubernetes
  Secrets in the build namespace, not Woodpecker database secrets — see secrets
  management above.
- If NATS is unavailable when CI tries to publish, CI fails the pipeline and alerts. A build that cannot announce itself is not a successful deployment.

---

### 5.2 NATS JetStream Cluster

**Responsibility:** Route deployment events between CI and hosts. Nothing else.

**Deployment topology:**

A three-node Raft cluster, with one NATS node running as a cloud-hypervisor microVM on each of the three homelab infrastructure hosts:

- **NAS** — always-on storage host; Attic and its signing key run on the NAS host, isolated from the NATS microVM
- **erebonia** — k3s/KubeVirt host; schedules Woodpecker build pods; CI build
  credentials are scoped to the build namespace; the NATS node is isolated in
  its own microVM
- **calvard** — general infrastructure host

Each NATS microVM is allocated **1 vCPU, 128MB RAM, and 512MB disk**.

NATS microVM startup is intentionally **last in the boot order** on each host, after step-ca and other services. This is safe because the cluster tolerates single-node loss — the other two nodes maintain quorum during any individual node's startup delay. The node comes up when it's ready, rejoins cleanly, and the cluster absorbs it without ceremony.

**Isolation properties:**

The host-side signing keys are outside the microVM trust boundary. A fully compromised NATS cluster cannot access either signing key. The dual-signature check protects against malicious build injection even in the worst-case NATS compromise.

**JetStream configuration:**

- Stream `builds.nixos.*`: retention `LastPerSubject` — each subject retains only the most recent build event. Hosts that reconnect receive current desired state, not history.
- Stream `activations.*`: retention `Limits` with 7-day window — activation results are facts; short history is useful for debugging.
- Persistence backed by NAS storage on the NAS node, replicated across all three nodes via Raft.
- Consumer configuration: `DeliverLastPerSubjectPolicy` — on connect, receive the most recent build event for the subscribed configuration, then subsequent events.

**Security:**

**TLS is mandatory.** Plain TCP connections are rejected.

**WebSockets are disabled.** No browser clients exist in this deployment. CVE-2026-27571 demonstrated that NATS WebSocket handling is exploitable pre-authentication:

```nix
services.nats.settings.websocket.no_tls = true;  # disabled
```

**Certificate authority — step-ca:**

Certificates are issued by the homelab's existing step-ca instance. 30-day lifetime with renewal attempted at 50% (15-day window). Certificates are cached on persistent disk — if step-ca is temporarily unavailable during renewal, the microVM continues operating with the cached certificate until step-ca recovers.

**Client authentication — NKeys:**

NATS NKeys (Ed25519) with JWT-based authorisation. Per-client subject permissions:

- CI credentials: publish to `builds.>`, subscribe to `activations.>`
- Host credentials: subscribe to `builds.nixos.<configuration>` only, publish to `activations.<hostname>` only
- No host can publish to `builds.>`

NKey credentials are distributed via sops-nix, never in plaintext in the Nix store.

**Availability:** The three-node Raft cluster survives single-node loss. Rolling updates proceed one node at a time while the other two maintain quorum — no deployment downtime. Each NATS microVM is a NixOS configuration in the flake, updated by the same deployment system it supports.

**Observability:** NATS exposes a monitoring HTTP endpoint (port 8222). The `prometheus-nats-exporter` with `-jsz=all` scrapes JetStream-specific metrics (`jetstream_*` prefix) covering stream message counts, consumer lag, Raft cluster state, and storage utilisation. An official Grafana/Perses-compatible dashboard exists for JetStream metrics.

---

### 5.3 Per-Host Coordinator (NixOS Module)

**Responsibility:** Receive build events, download and verify closures, activate configurations, publish results.

**Implementation:** A systemd service written in Rust, using the `async-nats` crate. Target: ~300–500 lines of application logic plus the NixOS module.

#### 5.3.1 Common Module and Deployment Topology

The homelab flake includes a **common module** that declares the deployment topology — the ordered dependency graph for the fleet. Each host's coordinator configuration is generated from this map. A host can still be deployed in isolation (its coordinator waits for its upstream host's activation result; if it times out, it proceeds independently), but when deploying the full fleet the common module governs sequencing.

```nix
# In the common module
fleetTopology = {
  deploymentOrder = [
    { host = "router";      dependsOn = null; }
    { host = "nas";         dependsOn = "router"; }
    { host = "workstation"; dependsOn = "nas"; }
  ];
  # Timeout for upstream activation result before proceeding independently
  dependencyTimeoutSeconds = 600;  # 10 minutes
};
```

Each host's coordinator configuration is derived from this:

```nix
# Generated per-host from the common module
services.fleetActivation.dependsOnActivation = "router";  # or null
services.fleetActivation.dependencyTimeoutSeconds = 600;
```

The CI deploy phase reads the same topology to determine the results-gated publication order.

#### 5.3.2 Module Interface

```nix
services.fleetActivation = {
  enable = true;

  nats = {
    # Connect to all three cluster nodes; client handles failover automatically
    servers = [
      "nats://nas.lan:4222"
      "nats://nuc2021.lan:4222"
      "nats://nuc2023.lan:4222"
    ];
    # NKey credentials via sops-nix; never plaintext in Nix store
    credentialsFile = config.sops.secrets.nats-credentials.path;
  };

  # The NixOS configuration name this host tracks
  # Subscribes to builds.nixos.<configuration>
  configuration = "router";

  # Source refs that trigger nixos-rebuild switch (permanent)
  productionRefs = [ "refs/heads/main" ];

  # Source ref patterns that trigger nixos-rebuild test (auto-revert)
  testRefPatterns = [ "refs/pull/*" ];

  # Binary cache to substitute from (Attic on NAS)
  substituters = [ "https://attic.nas.lan/homelab" ];

  # Pre-download closure before activation (mandatory for network infrastructure)
  preDownload = true;  # default: true

  # Wait for upstream host's activation result before activating
  # Set by the common module; null means no dependency
  dependsOnActivation = null;  # e.g. "router"
  dependencyTimeoutSeconds = 600;  # proceed independently after timeout

  # Local outbound queue for result messages during NATS unavailability
  outboundQueueSize = 10;  # default: 10; oldest dropped if full

  # Require both CI and Attic signatures before activating
  requireDualSigning = true;  # default: true

  # Test window duration before automatic revert
  testWindowSeconds = 900;  # 15 minutes

  # Post-activation connectivity check (reverts immediately if check fails)
  connectivityCheck = {
    enable = true;
    target = "1.1.1.1";
    timeoutSeconds = 30;
  };

  # Automatically roll back if nixos-rebuild switch returns non-zero
  rollbackOnFailure = true;  # default: true
};
```

#### 5.3.3 Activation Flow (Production)

```
receive builds.nixos.<configuration> event where source_ref matches productionRefs
  │
  ├── if activation already in progress: discard event, log warning, exit
  │
  ├── validate message (timestamp not stale, store path format valid)
  │
  ├── [if dependsOnActivation is set]
  │     subscribe activations.<upstream-host>
  │     wait for recent status=success (JetStream LastPerSubject)
  │     if timeout (dependencyTimeoutSeconds): proceed independently, log warning
  │
  ├── nix copy --from attic <store_path> --to /nix/store
  │     (pre-download entire closure before activation)
  │     (network path still up; old config still active)
  │
  ├── nix store verify --recursive --sigs-needed 2 <store_path>
  │     (verify both CI and Attic signatures; abort if either missing)
  │     (if requireDualSigning = false: --sigs-needed 1)
  │
  ├── nixos-rebuild switch --flake <flake_ref> --substituters ""
  │     (substituters disabled; everything already in local store)
  │
  ├── if nixos-rebuild exit code non-zero and rollbackOnFailure = true:
  │     nixos-rebuild switch --rollback
  │     (previous generation paths are local GC roots — no network needed)
  │     publish activations.<hostname> { status: "rolled-back",
  │       reason: "activation-failed", source_ref, store_path, timestamp }
  │     exit
  │
  ├── [if connectivityCheck.enable]
  │     ping connectivityCheck.target
  │     if fail: nixos-rebuild switch --rollback
  │              publish activations.<hostname> { status: "rolled-back",
  │                reason: "connectivity-failed", source_ref, store_path, timestamp }
  │              exit
  │
  └── publish activations.<hostname> { status: "success",
        generation, source_ref, store_path, timestamp }
```

**Two complementary rollback mechanisms:**

- `rollbackOnFailure`: catches failures _during_ activation — `nixos-rebuild switch` returns non-zero. Activation errors, service start failures. Information available locally as exit code.
- `connectivityCheck`: catches failures _after_ activation — switch succeeded but connectivity is broken. Bad firewall rules, routing changes. Detects what the exit code cannot.

Together these cover the same ground as deploy-rs's magic rollback, entirely locally, with no external actor.

#### 5.3.4 Activation Flow (Test)

```
receive builds.nixos.<configuration> event where source_ref matches testRefPatterns
  │
  ├── if activation already in progress: discard event, log warning, exit
  │
  ├── [same pre-download, dependency wait, and verification steps as production]
  │
  ├── nixos-rebuild test --flake <flake_ref> --substituters ""
  │     (activates config but does not update bootloader)
  │
  ├── start systemd timer: revert after testWindowSeconds
  │
  ├── publish activations.<hostname> { status: "testing", source_ref, store_path, timestamp }
  │
  ├── [wait for timer or production event]
  │
  ├── on builds.nixos.<configuration> event where source_ref matches productionRefs:
  │     cancel timer
  │     run full production activation flow for the new event
  │     (supersedes the test; if flake_ref matches, nixos-rebuild is a no-op)
  │
  └── on timer expiry:
        systemctl reboot
        (reboot restores previous generation via bootloader)
```

#### 5.3.5 Systemd Integration

```
After = network-online.target time-sync.target nix-daemon.service
Wants = network-online.target time-sync.target
```

`time-sync.target` is required to reject stale retained messages on startup. The revert timer is a separate transient systemd timer unit — purely local, no network dependency.

#### 5.3.6 Nix GC Interaction

```nix
# Added by the module automatically
nix.gc.automatic = false;  # or conservative: "--delete-older-than 30d"
```

Previous generation paths are GC roots by default. Made explicit to prevent misconfiguration — `nixos-rebuild switch --rollback` must work without network access.

---

### 5.4 Attic Binary Cache

**Responsibility:** Serve pre-built NARs to hosts.

**Hosting:** On the NAS, directly on the host (not in a microVM). The Attic signing key is isolated from the NATS microVM on the same host by the microVM boundary.

**Signing model:** Attic uses server-side managed signing. The signing keypair is generated and held by the Attic server; paths are signed on-the-fly when fetched. Hosts configure `nix.settings.trusted-public-keys` with both Attic's public key (from `attic cache info <cache>`) and the CI public key. The coordinator requires both signatures before activation.

**Configuration requirements:**

- Retention policy: minimum last 3 builds per host to support rollback; configurable per-cache
- GC runs as a separate single-instance process on a configurable interval
- Per-host pull tokens: hosts can pull, cannot push or administer
- Reachable from all LAN hosts; not internet-accessible

**Future direction — Attic HA:**

Attic is designed to run behind a load balancer with multiple replicated instances, using a distributed Postgres-compatible database for its narinfo index and metadata. Combined with the `nats-s3` gateway (see above) for S3-compatible blob storage backed by the NATS cluster, a fully HA Attic deployment is architecturally achievable: multiple Attic instances behind a load balancer, narinfo/metadata in a HA Postgres-compatible database (e.g., CockroachDB, Patroni), and NARs stored in NATS Object Store replicated across all three nodes.

Not adopted now because: the operational cost of a HA Postgres-compatible database is non-trivial; the NAS's ZFS pool already provides local durability; and Attic itself remains pre-1.0. Worth revisiting if Attic stabilises and the NAS becomes a reliability concern, or if a HA Postgres-compatible database is introduced for another reason (at which point Attic HA becomes a much smaller incremental step).

---

### 5.5 Result Aggregation (Optional)

Hosts publish activation facts to `activations.<hostname>`. Any subscriber can consume them without being known to the system in advance.

Suggested minimal implementation: a service subscribing to `activations.>` that writes structured logs or exposes Prometheus/Perses metrics. The event schema includes `source_ref` and `store_path`, making it a complete audit trail. Can be added later without modifying any other component.

---

## 6. Implementation Sequencing

This spec describes the full problem space to verify that the architecture does not paint itself into corners. The minimum viable implementation is substantially smaller.

**What must exist before anything works:**

1. **NATS JetStream cluster** — three microVM nodes (NAS, erebonia, calvard), 1 vCPU / 128MB RAM / 512MB disk each, TLS with step-ca, NKey credentials, JetStream streams with `LastPerSubject` retention
2. **Attic** — on the NAS, with CI signing and retention policy keeping last 3 builds per host
3. **Woodpecker CI** — server + config service microVM on erebonia (`saint-arkh`), with build execution through the k3s Kubernetes backend
4. **The coordinator daemon** — subscribe to `builds.nixos.<configuration>`, pre-download closure, verify dual signatures, `nixos-rebuild switch`, rollback on failure, connectivity check, publish to `activations.<hostname>`
5. **The common module** — deployment topology map, at minimum just the router with no dependencies

Deploy it first on the router only. Validate that a merge to main causes the router to update safely, rolls back on failure, and reports its result. Add the common module topology for additional hosts only after the router case works end-to-end.

**What the remaining sections are:**

- **Container integration (Section 9)** — verifies `builds.nixos.*` subject structure does not preclude `builds.containers.*`
- **Isolated and remote hosts (Section 10)** — verifies NATS model does not need to stretch to cover hosts it should not cover
- **Events as facts (Section 2.2)** — verifies event schema composes with future subscribers
- **Central coordinator (Section 2.4)** — verifies per-host model does not require rearchitecting later
- **Result aggregation (Section 5.5)** — verifies activation facts are complete enough for monitoring
- **Convergence check (Section 5.1)** — optional safety net; worth knowing about, not worth building first

---

## 7. Known Limitations and Tradeoffs

**Ordered rollouts are limited to the common module topology.** The `dependsOnActivation` mechanism provides linear ordering; complex DAG dependencies are not supported. A central coordinator layer could be built on top for more sophisticated sequencing.

**No coordinated rollback.** If a deployment succeeds on some hosts and fails on others, the fleet is in a split state. Results topics provide visibility; resolution requires human intervention.

**NATS cluster is an availability dependency for deployment delivery.** Total unavailability (loss of two or more nodes simultaneously) pauses deployments. Hosts remain on their last activated configuration. In practice, the three-node cluster survives any single-node failure or planned rolling update.

**Test window is a heuristic, not a guarantee.** The 15-minute revert window catches obvious breakage. Subtle failures (memory leaks, slow-manifesting failures) may not be caught. Manual rollback via NixOS generations remains available.

**Bootstrap is straightforward.** No important mutable state exists on any managed host beyond the ZFS pool. Machines can be rebuilt with nixos-anywhere or from a live disk at any time. The NATS cluster requires two nodes before quorum; bring up any two first, then the third joins automatically.

**erebonia and NAS are high-value targets.** erebonia's build namespace holds the CI signing key; the NAS holds the Attic signing key. Neither alone is sufficient for a malicious deployment. The default build profile uses gVisor (`runsc`), PSS Restricted, NetworkPolicy, and Kyverno to constrain compromised build jobs.

**Concurrent events are discarded, not queued.** A deployment event arriving mid-activation is discarded. JetStream `LastPerSubject` retention and CI's ability to republish ensure no permanent loss.

---

## 8. CI and Deployment Topology Reference

### 8.1 Full Pipeline Summary

```
[Forgejo] push/merge/PR event
    │
    ▼
[Woodpecker CI] (saint-arkh microVM on erebonia)
  woodpecker config service generates pipeline from flake outputs
    │
    ├── build phase (parallel, all NixOS configurations)
    │     per-step pod in woodpecker-builds namespace
    │     nix build .#nixosConfigurations.<host>.system
    │     nix store sign --key-file $CI_KEY --recursive
    │     attic push homelab ./result
    │
    └── deploy phase (sequential, order from common module)
          for each host in topology order:
            nats pub builds.nixos.<host> { flake_ref, store_path, source_ref, ... }
            nats sub --count 1 activations.<host>  # wait for result
            if rolled-back or timeout: abort, alert

[Attic on NAS] serves signed NARs on substituter requests

[NATS cluster] routes build events to coordinators, activation results to CI

[Per-host coordinator] (NixOS module on each managed host)
  receives builds.nixos.<configuration>
  waits for upstream host if dependsOnActivation is set
  nix copy --from attic (pre-download)
  nix store verify --sigs-needed 2
  nixos-rebuild switch / test
  rollback on failure or connectivity loss
  publishes activations.<hostname>
```

### 8.2 Host Classification

| Host type                        | Deployment path                 | Notes                             |
| -------------------------------- | ------------------------------- | --------------------------------- |
| LAN infrastructure (router, NAS) | NATS coordinator                | Network-safe activation mandatory |
| LAN workstations / servers       | NATS coordinator                | Standard                          |
| IoT VLAN devices (Pi, etc.)      | deploy-rs from build server     | Cannot reach NATS cluster         |
| Cloud / remote edge hosts        | deploy-rs over WireGuard/SSH    | Minimal attack surface            |
| NATS microVMs                    | NATS coordinator (self-managed) | Rolling update via cluster quorum |
| Woodpecker microVM               | NATS coordinator (self-managed) | Agent drains before restart       |

---

## 9. Future Direction: k3s Workload Integration

The same pipeline applies naturally to OCI image builds and k3s workload
deployment.

CI builds OCI images as Nix derivations, pushes them to the Forgejo container
registry, and publishes events to `builds.containers.<name>`. The dynamic
workload path then updates the Flux-watched manifest source with the image
digest, or publishes a narrowly scoped event consumed by the cluster deployment
controller once that shape exists.

Trust model: OCI digest pinning serves the same role as Nix store signature verification — the event specifies an exact digest that the registry cannot substitute.

**Dependency on the workloads plan.** Building this before
`llm-notes/wip/k3s-cluster-workloads-plan.md` settles the dynamic-manifest path
would create churn. Nothing in the current design needs to change to support
this later — the NATS subject namespace, coordinator module structure, and
result aggregation pattern all accommodate workload events alongside NixOS
closure events.

---

## 10. Future Direction: Isolated and Remote Hosts

Not all hosts can or should participate in the NATS-based fleet activation system. Two categories require deploy-rs:

**Network-isolated hosts** — IoT VLAN devices that are deliberately cut off from the internal network. Punching holes in the VLAN boundary to reach the NATS cluster or Attic would undermine the segmentation.

**Remote or edge hosts** — cloud hosts acting as ingress guards or VPN endpoints. Minimal open ports; outbound connection to an internal NATS cluster would require exposing it to the internet or VPN. deploy-rs's magic rollback is particularly valuable here: if a bad config breaks SSH access, automatic rollback is the only recovery path.

For both categories, push-based deployment from the build server via deploy-rs is correct. The build server is inside the trusted network and can reach isolated hosts (via specific VLAN routing rules) and remote hosts (via WireGuard or public IP). The trust model is appropriate: these hosts trust the build server's SSH key.

**Signing model for deploy-rs hosts:**

deploy-rs pushes closures directly from the build server's local Nix store over SSH, bypassing Attic entirely. These hosts do not receive Attic-signed paths — only paths that were built or substituted locally on the build server.

The appropriate signing approach is: the build server signs paths with the CI key before pushing (`nix store sign --key-file $CI_KEY --recursive <path>`), and deploy-rs hosts configure `nix.settings.trusted-public-keys` to trust the CI key. This gives deploy-rs hosts the same CI signature guarantee without the Attic signature, which is appropriate given that Attic is unreachable from their network position. The dual-signature model does not apply to these hosts — single CI signature verification is the correct trust model for push-based deployments from a trusted build server.

Both paths originate from the same build phase in Woodpecker. The deploy phase runs both paths independently after builds complete.

---

## 11. Companion Tools

| Concern                           | Tool                                                                      |
| --------------------------------- | ------------------------------------------------------------------------- |
| Initial host provisioning         | nixos-anywhere + disko                                                    |
| Binary cache                      | Attic (on NAS)                                                            |
| Secret management (runtime)       | sops-nix                                                                  |
| Secret management (operator)      | passage                                                                   |
| CI server                         | Woodpecker CI                                                             |
| Flake pipeline generation         | Woodpecker External Config Service (woodpecker-flake-pipeliner candidate) |
| Event bus                         | NATS with JetStream (3-node Raft cluster)                                 |
| Microvm management                | microvm.nix (cloud-hypervisor)                                            |
| Internal TLS certificates         | step-ca                                                                   |
| Monitoring                        | Prometheus + Perses                                                       |
| Multi-host flake organisation     | flake-parts                                                               |
| Dynamic workload layer            | k3s + Flux (future — see Section 9)                                       |
| Isolated / remote host deployment | deploy-rs (see Section 10)                                                |

---

## Appendix: CI System Comparison

Forgejo is used as the git forge only — code storage, PR/merge events, container registry. Forgejo's built-in Actions runner infrastructure is not used. The comparison below covers the CI systems evaluated as the build execution layer.

| Requirement               | Woodpecker CI                                    | buildbot-nix                        |
| ------------------------- | ------------------------------------------------ | ----------------------------------- |
| Build isolation           | Kubernetes backend + RuntimeClass/Policy controls | Infrastructure-level (worker in VM) |
| Attic integration         | **Native plugin**                                | Systemd watcher service             |
| Flake pipeline generation | **External config service API**                  | Auto `.#checks` discovery           |
| NATS events               | CLI step                                         | Custom step                         |
| Staggered deploys         | DAG + multi-workflow                             | Buildbot scheduler                  |
| Rebuild safety            | Retriable pods; cluster/server health gates      | Worker drain                        |
| Dev branch builds         | Full PR/branch triggers                          | Auto PR + default branch            |
| Forgejo integration       | Supported (Codeberg uses it)                     | Via Gitea-compatible API            |
| nixpkgs packaging         | `woodpecker-server`; Kubernetes backend built in | Flake input (not in nixpkgs)        |

Woodpecker CI was chosen for: native Attic plugin, External Configuration API for large flake target sets, Kubernetes backend support that composes with the existing k3s isolation stack, and proven Forgejo integration at Codeberg scale.

Hercules CI was eliminated: does not support Forgejo (GitHub and GitHub Enterprise only, as of early 2026).

buildbot-nix remains a strong alternative if deep Nix evaluation awareness (parallel flake evaluation via `nix-eval-jobs`) matters more than plugin ecosystem maturity.
