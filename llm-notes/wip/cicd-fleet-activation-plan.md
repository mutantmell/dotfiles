# CI/CD Pipeline and Fleet Activation Plan

Status: WIP, revised 2026-10-20 for Comin and a CI-promoted release branch.
Specification: `../specs/cicd-fleet-management.md`.

This replaces the earlier NATS/custom-coordinator implementation sequence. The
initial goal is useful self-hosted pull updates, with local evaluation and cached
builds; stricter Talos-style host lockdown remains paused pending KVM recovery.
Use open-source/self-hostable components only. nix-fleet is a future option whose
readiness does not gate this plan. Previous design/history is available in Git.

## Updater decision

Comin is selected initially for signed-source verification, persistent deployment
tracking, observability, and native pause controls. Built-in `system.autoUpgrade`
with a CI-published HTTPS flake was assessed as a smaller alternative, but is not
the selected implementation. Reconsider only with evidence that its smaller
service footprint outweighs custom release verification/state/operational work.

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
      local-backend worker boundary as well as Kubernetes runner policies. Use a
      separate trusted publishing runner/service or proven disposable reset
      boundary; withholding secrets by event is insufficient on a persistent worker.
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
      complete releases available regardless of age and locally rooted. Verify the
      suspected obsolete `retention-period` key against pinned source and effective
      per-cache/default retention. Optional historical expiry (e.g. 90 days) must
      not expire a current or designated recovery release.
- [ ] Configure target substituters, trusted keys, and any read authentication.
      Test cache outage, missing transitive paths, and cache recovery.

## Phase 3: Protected release promotion

- [ ] Pin Comin and confirm installed Flux verification support; choose compatible
      GPG/SSH keys. Configure signed candidate/merge commits before validation,
      independent public-key provisioning, and overlapping rotation. Signatures
      authenticate source; protected promotion authorizes deployment.
- [ ] Validate Flux rendering/schema and immutable runtime dependency references
      alongside enrolled host builds. Do not rewrite/sign commits after testing.
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
      branches, enable candidate-signature verification, and verify Forgejo read
      authentication plus polling behavior. Persist Comin state under impermanence.
- [ ] Confirm evaluated toplevel matches CI evidence; configure and test no local
      or remote compilation with the pinned invocation. Missing artifacts must
      postpone updates while preserving the running system. Include cold source/eval
      dependencies and the `max-jobs = 0`/`preferLocalBuild` exception; this is
      compilation minimization, not a claim of artifact-only host execution.
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
      Test skipped releases and offline rejoin: preserve backwards compatibility
      or gate on readiness of every required host and control incompatible rejoin.
      Include a k3s host missing multiple minor upgrades: require explicit supported
      intermediate-version catch-up before following the latest release.
- [ ] Enroll erebonia/calvard and ideally liberl gradually, retaining cache and
      recovery availability. Keep manual deploy/bootstrap tools usable.
- [ ] Add host-specific health/status reporting and update-freeze runbooks before
      enabling routine unattended changes.
- [ ] For k3s upgrades document SQLite datastore plus token/identity backup, fresh
      snapshots and off-host restore exercise, supported sequential minor/version
      compatibility review, and API/node/pod/KubeVirt/network health gates. Keep
      application/VM data backups separate; routine supported upgrades stay small.

## Flux delivery on the same release channel

- [ ] Wire a read-only Git source following protected `release`, separately from
      publisher credentials, with signature verification and per-cluster paths.
- [ ] Keep Nix dependency pins authoritative and generated YAML committed; check
      regeneration, deployed image/chart digests or exact immutable chart artifacts.
- [ ] Replace Flux bootstrap chart with pinned NixOS-generated manifests; retain
      a single bootstrap owner, and migrate add-ons without competing controllers.
- [ ] Define Kubernetes dependencies/health, CRD lifecycle, Helm remediation and
      persistent-resource pruning policies. These do not gate host readiness.
- [ ] Exercise shared-release recovery and native reconciliation suspension;
      platform-dependent changes require compatible transitions or readiness holds.

## Independent and later work

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
