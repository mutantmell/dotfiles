# NixOS Homelab Pipeline and Fleet Activation: Specification

Status: Active design, revised 2026-10-19. This replaces the NATS/custom
coordinator design; historical details remain in Git history. Implementation
sequencing lives in `../wip/cicd-fleet-activation-plan.md`.

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

1. Reviewed PRs merge into protected `main` after required checks.
2. Trusted CI checks the exact main commit and builds the toplevel for every
   host enrolled in the shared release channel, using the committed lock file.
3. CI uploads each complete runtime closure to Attic, verifies availability and
   records commit, configuration, and store path evidence. A successful check
   matrix alone is not proof that all host closures have been built and cached.
4. Only after all required checks and uploads succeed, a serialized promotion
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
code is trusted for publication; that trust boundary must be explicit.

Cache signatures establish artifact integrity/trust in the cache publisher.
Protected-branch promotion establishes release authorization. Two signing keys
reachable through one CI publisher do not create independent approval. No
production PR test activations are permitted; Comin testing branches are disabled.

## 3. Target contract

- Pin Comin and configure the intended Git remote, `release` branch, hostname,
  authentication, polling interval with appropriate staggering, and cache trust.
- Restrict both local compilation and remote builders. Validate the actual pinned
  Comin/Nix invocation: a missing dependency must leave the current system running
  and postpone the update, rather than compile locally or remotely. Treat this as
  an acceptance test, not a solved property of merely configuring a substituter.
- Prove target evaluation selects the same host closure CI published. Avoid impure
  or host-dependent inputs; test source-fetch and Git authentication requirements.
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
by this decision. Define their release and recovery policy separately.

## 5. k3s and workload ownership

The updater must run as a host service independently of k3s/Flux. NixOS owns the
host OS, networking, mounts, k3s runtime and bootstrap. Flux is the intended owner
of Kubernetes add-ons, applications, and KubeVirt resource definitions after the
Git source/reconciliation path is wired; installed controllers alone do not mean
that migration is complete. Comin must not independently reconcile those resources.

k3s upgrades require a fresh datastore backup with verified off-host recovery,
version compatibility review, and API/node/core-pod/KubeVirt/network checks.
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

## 7. Acceptance criteria

- Trusted CI publishes complete closures before exact-commit release promotion.
- Competing/failed jobs cannot regress or partially authorize a release.
- PR jobs cannot publish artifacts or advance release.
- A disposable Comin target follows only release and runs the CI-selected closure.
- Cache misses and unavailable Git/cache endpoints postpone updates safely without
  local or remote compilation.
- Recovery and observability work through interruption, health failure, and reboot,
  including while k3s is unavailable.
- Physical-host enrollment and access restrictions wait for validated KVM recovery.
