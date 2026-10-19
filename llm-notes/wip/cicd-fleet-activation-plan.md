# CI/CD Pipeline and Fleet Activation Plan

Status: WIP, revised 2026-10-19 for Comin and a CI-promoted release branch.
Specification: `../specs/cicd-fleet-management.md`.

This replaces the earlier NATS/custom-coordinator implementation sequence. The
initial goal is useful self-hosted pull updates, with local evaluation and cached
builds; stricter Talos-style host lockdown remains paused pending KVM recovery.
Use open-source/self-hostable components only. nix-fleet is a future option whose
readiness does not gate this plan. Previous design/history is available in Git.

## Alternative under investigation

Comin remains the agreed initial direction. A CI-published HTTPS tarball flake
consumed by built-in `system.autoUpgrade` is an undecided alternative with fewer
updater dependencies. It can retain the same validation/cache/publication gates;
a generated minimal flake referring to exact prebuilt store paths is also being
investigated. Neither variant has yet passed end-to-end NixOS rebuild, activation,
recovery, and no-compilation acceptance. Mutable-object freshness, atomic promotion,
release authorization, and rollback semantics need explicit validation before a
choice replaces this plan. See the upstream
[NixOS auto-upgrade module](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/tasks/auto-upgrade.nix).

## Current repository evidence

- Forgejo on creil is the review/source endpoint; Woodpecker's server is
  saint-arkh, outside k3s so its control-plane state remains independent.
- `.woodpecker/full-checks.yml` selects `runner: nixos-kvm`, invokes the repository
  runner, and produces check summaries. CI is no longer quick-preflight-only.
- `hosts/erebonia/k3s/woodpecker-ci-worker-vm.nix` declares a KubeVirt local-backend
  worker. Kubernetes-backend execution is also declared. Establish which lanes
  run live and their isolation before extending either; do not assume every job
  is a restricted build pod. The worker's 16 GiB allocation is not a statement
  that the physical host has only 16 GiB RAM.
- Attic is configured on zeiss under liberl. Cache publishing, retention,
  credentials, and complete-closure coverage still require verification.
- `hosts/erebonia/k3s/flux.nix` installs Flux but the Git source/sync wiring remains
  incomplete. NixOS-managed cluster manifests have not all moved to Flux.

These are checkout facts, not claims of live deployment or successful acceptance.

## Phase 1: Prove validation and publication boundaries

- [ ] Inventory live Woodpecker lanes, capacity, full-check results, summaries,
      branch protection, and required-check policy. Preserve per-process checks
      through `scripts/run-checks.sh`; do not use broad `nix flake check`.
- [ ] Separate untrusted PR execution from trusted main publication. Audit the
      local-backend worker boundary as well as Kubernetes runner policies.
- [ ] Keep release-promotion and cache-write/signing credentials out of PR jobs.
      Define a trusted publication pipeline that PR-controlled config cannot
      use to extract credentials.
- [ ] Retain an operator/out-of-cluster build and repair route for broken k3s.

## Phase 2: Attic coverage and retention

- [ ] Select the initial enrolled-host set and exact toplevel outputs; build each
      from the same main commit and committed lock file after required checks.
- [ ] Publish complete runtime closures to zeiss/Attic, verify retrieval, and
      retain commit/configuration/store-path evidence before promotion.
- [ ] Audit retention/GC against the pinned Attic version. Keep active and recovery
      closures available and locally rooted; define an explicit retention window.
- [ ] Configure target substituters, trusted keys, and any read authentication.
      Test cache outage, missing transitive paths, and cache recovery.

## Phase 3: Protected release promotion

- [ ] Create protected `release`; bootstrap it only from a fully validated and
      cached main commit. Define how enrollment changes expand the build gate.
- [ ] Serialize trusted promotions; re-read the remote, require fast-forward
      ancestry, and reject late/obsolete jobs. Push the exact tested commit.
- [ ] Verify failed checks/uploads never promote and no job can force-push or
      move release backwards. Scope credentials and protect against other writers.
- [ ] Document emergency freeze and recovery: pause consumption/promotion as
      appropriate; recover hosts explicitly. Never force-push release backwards
      to simulate rollback. A forward revert must pass the normal release gate.

## Phase 4: Comin proof in disposable VMs

- [ ] Pin Comin, set remote/hostname, follow only `release`, disable testing
      branches, and verify Forgejo authentication plus polling behavior.
- [ ] Confirm evaluated toplevel matches CI evidence; configure and test no local
      or remote compilation with the pinned invocation. Missing artifacts must
      postpone updates while preserving the running system.
- [ ] Exercise interrupted fetch/activation, Git/cache outages, retries, service
      health failures, reboot failures, retained generations, and GC protection.
- [ ] Establish what recovery Comin actually supplies and fill gaps with tested
      operator procedures or narrowly scoped mechanisms. Do not claim automatic
      health/boot rollback merely from deployment history.
- [ ] Prove host update/recovery does not require functioning k3s/Flux.

## Phase 5: Recovery-ready host enrollment

Physical rollout and stricter access restrictions remain paused until KVM or
out-of-band recovery is ready and exercised. Phases 1–4 can progress meanwhile.

- [ ] Select a low-risk canary based on dependencies and recovery access, rather
      than always selecting liberl or the router first.
- [ ] Define/test maintenance pause controls and host-by-host observation. A shared
      release branch does not itself enforce sequential or health-gated rollout.
- [ ] Enroll erebonia/calvard and ideally liberl gradually, retaining cache and
      recovery availability. Keep manual deploy/bootstrap tools usable.
- [ ] Add host-specific health/status reporting and update-freeze runbooks before
      enabling routine unattended changes.
- [ ] For k3s upgrades require fresh recoverable datastore backups, version review,
      and API/node/pod/KubeVirt/network health gates. Keep risky upgrades deliberate.

## Independent and later work

- Complete Flux source/reconciliation ownership separately from host updates.
- Evaluate shared blob storage across Attic, CI artifacts, backups, k3s snapshots,
  and applications. Choose backend/placement/retention by requirements; Garage is
  a candidate. This does not block Comin or require migrating Attic first.
- Dependency-update PR automation and dashboards can follow reliable CI. Keep
  Nix flake updates separate from the Flux dependency registry/committed YAML
  flow described in `../reports/k3s-flux-helm-ownership.md`. Updates to
  `hosts/erebonia/k3s/woodpecker-images.nix` must keep image digests, fixed-output
  hashes, node preload archives, and workload image references consistent.
  Start manually, then schedule reviewed fork-and-pull PRs with scoped credentials.
- Preserve agent-readable check summaries and failure-log access; the completed
  feedback work is recorded in `../done/agent-ci-feedback-loop-plan.md`.
- Add OpenWrt configuration/image validation as a separate CI lane, with its own
  deployment/recovery acceptance; Comin does not update OpenWrt.
- Assess scheduled build-only checks against the committed lock file and actual
  capacity. Report main/release failures, stale hosts, failed activations, and
  recovery attempts through monitoring without reintroducing an event broker.
- Document rotation for cache publisher credentials/keys, release-promotion
  credentials, host Git/cache read credentials, and Woodpecker OAuth secrets.
- Reassess nix-fleet or another artifact-only updater after its capabilities and
  recovery behavior are demonstrated. Preserve the reviewed release/cache model.
- NATS, custom coordinators, dual-signature independent-approval claims, and live
  production PR activation are removed from the active initial scope.

## Completion evidence

Record exact commits, cached host paths, competing-promotion tests, negative
credential/build tests, and recovery exercises. Documentation/configuration alone
does not mark these phases complete. Operator guidance belongs in
`../../docs/host-pull-updates.md` as capabilities are actually implemented.
