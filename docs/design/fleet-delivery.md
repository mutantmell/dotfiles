# NixOS Homelab Pipeline and Fleet Activation: Specification

Status: Active design, revised 2026-10-20. This replaces the NATS/custom
coordinator design; historical details remain in Git history. Implementation is split into the fleet and Flux issues in [the issue index](../work-tracking.md).

## 1. Goal and scope

Use an entirely open-source, self-hostable delivery path for reviewed NixOS
updates. Start with Comin following a protected `release` branch and substituting
CI-built systems from Attic on liberl (zeiss). erebonia and calvard, and ideally
liberl, should eventually operate as tightly restricted VM hosts with minimal
routine administrative access.

Comin is an intermediate model: targets still fetch source and evaluate Nix
locally. Cache coverage must avoid compilation; it does not eliminate evaluation.
Stricter Talos-style operation consuming only prebuilt artifacts is deferred
until KVM/out-of-band recovery is ready. nix-fleet is a future candidate, not a
prerequisite or a promised migration schedule. Cachix Deploy and other proprietary
control planes are excluded.

This specification does not implement provisioning, secret bootstrap, OpenWrt
updates, or Kubernetes application reconciliation. Existing operator deployment
and recovery tools remain necessary. passage/operator tooling owns private guest
bootstrap identities; sops-nix owns ordinary service secret decryption. Release
metadata and cache artifacts must never contain decrypted secrets.

## 2. Delivery and authorization

1. Reviewed PRs merge into protected `main` after required checks. The candidate
   commit must already carry its trusted signature before release validation.
2. Trusted CI checks the exact main commit and builds the toplevel for every
   host enrolled in the shared release channel, using the committed lock file.
3. CI uploads each complete runtime closure to Attic, verifies availability and
   records commit, configuration, and store path evidence. A successful check
   matrix alone is not proof that all host closures have been built and cached.
4. Validate committed Flux manifests and their pinned runtime dependencies.
   Only after all required checks and uploads succeed, a serialized promotion
   step fast-forwards protected `release` to that exact tested main commit.
5. Comin polls `release`, evaluates its explicitly selected host configuration,
   substitutes the cached closure, and activates according to validated policy.

Release must point to the tested commit itself, not a new merge or cherry-pick.
Concurrent CI completion must never move it backwards: re-read the remote under
serialization, require the existing release to be an ancestor of the candidate,
reject obsolete/divergent candidates, and use a normal fast-forward-only push.
A failed promotion must not fall back to force pushing. Hosts may skip intermediate
commits; every promoted commit must satisfy the complete enrolled-host build gate.

Protect release against manual/agent writes and force pushes. Restrict the
promotion credential to the trusted publisher and release ref where supported.
PR execution must have neither that credential nor cache-write/signing credentials.
Do not expose publisher secrets to PR-controlled pipeline execution. Reviewed main
code is trusted for publication; that trust boundary must be explicit. The
persistent local-backend PR worker must not later execute privileged publishing
with secrets: use a separate trusted publishing runner/service, or a demonstrably
clean disposable boundary with reset between trust domains. Event-based secret
scoping alone cannot prevent PR jobs leaving processes or modified state.

Cache signatures establish artifact integrity/trust in the cache publisher.
Protected-branch promotion establishes release authorization. Two signing keys
reachable through one CI publisher do not create independent approval. No
production PR test activations are permitted; Comin testing branches are disabled.

### Source signatures and promotion authority

Pin Comin and establish the actual Flux source-controller version before choosing
a shared supported OpenPGP/SSH verification format. Forgejo-signed merge commits
are the proposed candidate source; configure and test that policy rather than
assuming all merges are signed. Signing after validation changes the commit hash,
so promote the original signed, tested hash without rewriting it. A source
signature authenticates its signer, not successful CI: protected release promotion
is the approval boundary. Do not introduce post-CI signed tags unless the selected
consumers demonstrably support that policy. Provision verification keys separately
from repository contents and document overlapping-key rotation and revocation.

## 3. Target contract

- Pin Comin and configure the intended Git remote, `release` branch, hostname,
  authentication, polling interval with appropriate staggering, and cache trust.
- Restrict both local compilation and remote builders. Validate the actual pinned
  Comin/Nix invocation: a missing dependency must leave the current system running
  and postpone the update, rather than compile locally or remotely. Treat this as
  an acceptance test, not a solved property of merely configuring a substituter.
  `max-jobs = 0` still permits `preferLocalBuild` derivations; Comin minimizes
  compilation but is not an artifact-only execution boundary. Resolve any exceptions
  in the pinned configuration before enrollment, or keep activation gated.
- Prove target evaluation selects the same host closure CI published. Avoid impure
  or host-dependent inputs; test source-fetch and Git authentication requirements
  on a cold target. Runtime closures do not cover every source/evaluation dependency. Test missing source
  inputs and transitive store paths without mandating a custom evaluation cache.
- Persist Comin state/history under impermanence; loss of that state can remove
  ancestry protections. Configure native suspend/resume and switch inhibitors.
- Bound update attempts, serialize activation, retain enough local recovery state
  and GC-protected generations, and surface failures and running revisions.
- Test interrupted downloads/activation, service health failure, retry behavior,
  failed boots, and recovery before enabling unattended production updates.

Comin history and retained NixOS generations alone do not prove automatic rollback.
Where the pinned tooling lacks the required recovery behavior, keep activation
operator-gated until a tested procedure or narrowly scoped mechanism supplies it.
Do not remove recovery SSH/console access ahead of that proof and KVM readiness.

## 4. Rollout and failure domains

Begin in disposable VMs, then enroll one low-risk host after recovery is ready.
There is no hard-coded liberl-first or router-first order. Comin polling a shared
branch does not supply a cross-host health barrier. Initial production updates
must therefore use explicit maintenance/pause controls and observed health between
host activations. Define and test those controls before claiming sequential rollout.

If change risk demands independent promotion, introduce per-host release refs or
another explicit gate in a later revision. Do not silently assume one shared ref
coordinates reboots. Preserve cache availability, prefetch before disruptive work,
and retain locally usable recovery closures if liberl/Attic is unavailable.

thebeyond, intermittent workstations, and OpenWrt are not automatically enrolled
by this decision. Define their release and recovery policy separately. Persistent
workstation enrollment is specified in the [workstation lifecycle contract](workstation-lifecycle.md)
and [guest-updater issue](https://forgejo.internal/mutantmell-net/dotfiles/issues/261); it must
expand the release build gate before guests follow that channel.

Offline/paused consumers may skip any number of intermediate releases. Separate
commits and polling jitter do not enforce a sequence. Prefer transitions compatible
with older supported host states. Otherwise hold promotion/consumption until every
required host has demonstrated readiness, with an explicit policy for offline
hosts and their rejoin/recovery. A readiness observation is not a permanent
guarantee: prevent rollback or rejoin into incompatible platform states.
In particular, an offline k3s host must not jump across unsupported minor versions
just because `release` advanced. Keep its updater paused and recover through
explicit intermediate versions, or require verified sequential catch-up before
normal convergence. A forward-only Git history does not enforce version-by-version
activation.

## 5. k3s and workload ownership

The updater must run as a host service independently of k3s/Flux. NixOS owns the
host OS, networking, mounts, k3s runtime and bootstrap. Flux is the intended owner
of Kubernetes add-ons, applications, and KubeVirt resource definitions after the
Git source/reconciliation path is wired; installed controllers alone do not mean
that migration is complete. Comin must not independently reconcile those resources.

Flux follows the same protected `release` branch, using read-only source credentials
distinct from promotion credentials. Use a committed per-standalone-cluster path
(suggested `clusters/erebonia/` and later `clusters/calvard/`). Flux `dependsOn`,
`wait`, and health checks order Kubernetes resources, not host upgrades. Define
maintenance freezes for reconcilers as well as host updaters.

The Nix dependency registry is authoritative; commit generated Flux YAML and
check regeneration in CI. Pins must survive into deployed references: use image
digests and digest-pinned OCI charts, or distribute exact verified charts through
vendored/controlled immutable artifacts. A CI fetch hash plus a mutable runtime
version reference is insufficient. Initially NixOS alone owns Flux bootstrap
upgrades; migrate existing `autoDeployCharts` with explicit controller handoff,
CRD and prune/deletion policies, and bounded Helm remediation. Flux must not
simultaneously manage its own bootstrap objects. See the
[ownership report](cluster-ownership.md).

k3s currently uses SQLite. Maintain local snapshots plus fresh pre-platform-upgrade
backups of the datastore and required server token/identity material, verified
off-host copies, and an isolated restore exercise. Document a consistent SQLite
backup method (including any required service stop), not an arbitrary live file
copy. Existing token configuration
must be inventoried, not assumed absent. Application volumes and VM disks need
separate backups. Follow supported sequential minor upgrades after compatibility
review, including KubeVirt; routine patch/minor upgrades need not become projects.
Check API/node/core-pod/KubeVirt/network health.
An OS generation rollback does not reverse datastore migrations. Keep risky
platform upgrades deliberately gated until their recovery procedures are proven.

## 6. Supporting infrastructure and deferred work

Woodpecker remains the CI engine; Attic/zeiss on liberl remains the binary cache.
Keep build/repair options usable when k3s cannot schedule CI. NATS, a three-node
broker cluster, the custom root coordinator, event schemas, and a bespoke
pipeline-generation service are outside the initial scope. Notifications may
later accelerate polling without becoming deployment authority.

Shared blob storage remains a separate worthwhile multi-consumer project: assess
Attic objects, CI artifacts, application backups/uploads, and k3s snapshots against
actual backend compatibility, retention, sizing, and failure-domain requirements.
Garage is a candidate, not a prerequisite or settled choice. Object storage does
not replace CSI/block storage for VM disks or offsite backups.

Audit effective per-cache retention against the pinned Attic source/configuration:
the existing `retention-period` key may be obsolete; verify support for
`default-retention-period` and actual cache settings before changing them. Preserve
complete current and designated recovery releases regardless of age, both in the
cache and as appropriate local roots. A possible 90-day history window is only a
capacity-dependent suggestion, not protection for a still-current old release.
Report desired/running revision, failures, stale hosts, and pending reboots through
the existing monitoring stack; define credential/key rotation and outage behavior.

## 7. Acceptance criteria

- Trusted CI publishes complete closures before exact-commit release promotion.
- Competing/failed jobs cannot regress or partially authorize a release.
- PR jobs cannot persist into the privileged publisher, publish artifacts, or
  advance release; candidate signatures verify in both pinned consumers.
- Offline/rejoining consumers cannot bypass required platform prerequisites.
- Deployed chart/image bytes match the dependency registry, not just CI fetches.
- A disposable Comin target follows only release and runs the CI-selected closure.
- Cold-source failures, cache misses, and unavailable Git/cache endpoints postpone
  updates safely; build restrictions and `preferLocalBuild` exceptions are tested.
- Recovery and observability work through interruption, health failure, and reboot,
  including while k3s is unavailable.
- Physical-host enrollment and access restrictions wait for validated KVM recovery.
