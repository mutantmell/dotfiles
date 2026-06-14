# k3s / Flux Helm Ownership Report

Date: 2026-06-13

## Executive summary

The long-term target should be:

> **NixOS/k3s bootstraps the cluster and Flux. Flux owns Kubernetes desired
> state. Nix owns dependency pins, rendering, and validation.**

The repo should not treat the current `services.k3s.autoDeployCharts` usage as
the desired end state. It was a convenient bootstrap path, but the community and
upstream controller semantics point toward a Flux-heavy GitOps model:

- Use k3s' deploy controller only for the minimum bootstrap layer needed to get
  Flux running and pointed at this repository.
- Manage that one bootstrap dependency with the same Nix pin/update discipline:
  a pinned Flux release generates the bootstrap manifests, and
  `services.k3s.manifests` applies them.
- Use Flux `Kustomization` and `HelmRelease` resources for platform add-ons and
  workloads after bootstrap.
- Keep the repo's Nix discipline by storing dependency selection in Nix data or
  generated artifacts, with checks that rendered Flux manifests and dependency
  pins stay reproducible.

This report resolves two related questions:

1. **Version management:** dependency versions and component configuration
   should be separated. Nix should own dependency identity and validation;
   component values remain with the component using the dependency.
2. **Ownership boundary:** Flux should be the only long-running owner of Helm
   releases. k3s should remain a bootstrap installer, not a competing release
   reconciler.

## Current repo state

`hosts/erebonia/k3s/` currently uses the NixOS k3s module's
`services.k3s.autoDeployCharts` for several Helm charts:

- `cert-manager` in `cert-manager.nix`
- `flux2` in `flux.nix`
- `kyverno` in `kyverno.nix`
- `rke2-multus` in `multus.nix`

This has one important strength: the NixOS module fetches charts at build time
as fixed-output artifacts, so the chart archive is pinned by both version and
hash. That matches the repo's usual dependency-management posture better than
plain in-cluster Helm repository polling.

But it has two structural problems:

- The chart dependency tuple (`repo`, `name`, `version`, `hash`) is mixed into
  the same modules as component configuration (`values`, local manifests, host
  comments).
- k3s and Flux can both own Helm releases, giving the repo two controllers for
  the same class of object without a durable rule for which one should own what.

## What upstream semantics imply

### k3s deploy controller is bootstrap-oriented

K3s auto-applies files found under
`/var/lib/rancher/k3s/server/manifests` on startup and when files change. It
tracks them as `AddOn` resources. K3s explicitly documents that deleting a file
from that directory does **not** delete the corresponding Kubernetes resources.

That deletion behavior is the load-bearing difference. It makes the deploy
controller useful for packaged components and bootstrap material, but it is not
a strong long-term ownership model for add-ons expected to move, disappear,
roll back, or be health-gated.

K3s also includes a Helm controller driven by `HelmChart` CRDs, and the docs
describe installing a Helm chart by placing a single manifest file on disk.
This is convenient, but it is still part of the deploy-controller/AddOn model.

Sources:

- K3s packaged components: https://docs.k3s.io/installation/packaged-components
- K3s Helm controller: https://docs.k3s.io/add-ons/helm

### Flux is the long-running reconciler

Flux is designed for declarative, version-controlled Kubernetes operations. Its
bootstrap flow commits Flux component and sync manifests, installs the
controllers, and configures them to track a repository path.

Flux's Helm controller reconciles `HelmRelease` resources and supports Helm
actions such as install, upgrade, test, uninstall, and rollback. It also detects
and corrects drift. Flux `Kustomization` resources prune objects removed from
Git, which gives Flux the deletion semantics missing from the k3s AddOn path.

Sources:

- Flux get started / bootstrap model: https://fluxcd.io/flux/get-started/
- Flux Helm releases: https://fluxcd.io/flux/components/helm/helmreleases/
- Flux Helm release guide: https://fluxcd.io/flux/guides/helmreleases/
- Flux Helm chart sources: https://fluxcd.io/flux/components/source/helmcharts/

## Most important decision factor

The decisive factor is **controller lifecycle semantics**, not whether both
systems can express Helm chart installation.

The k3s deploy controller is an auto-apply bootstrap mechanism. Flux is a
GitOps reconciliation system. Once Flux exists, Flux is the more idiomatic owner
for Kubernetes desired state because it provides the lifecycle operations the
repo will need for platform add-ons and workloads: pruning, drift correction,
health/status, rollback, and clean deletion.

The repo's Nix-first dependency model remains important, but it should not force
k3s to remain the Helm release owner. The cleaner separation is:

- **Nix owns dependency selection and generated/validated manifests.**
- **Flux owns Kubernetes reconciliation.**
- **k3s owns cluster bootstrap.**

## Recommended target architecture

### Bootstrap layer: NixOS / k3s

The NixOS host configuration should install k3s and provide the minimum
manifests required to start Flux. This layer may include:

- k3s package/version and server flags
- host-level networking, firewall, runtime, persistence, and CA/OIDC wiring
- Flux controllers
- Flux source/sync objects pointing at the monorepo path
- emergency bootstrap RBAC if required before Flux is healthy

Avoid installing ordinary platform add-on Helm charts through
`autoDeployCharts` in the final state.

Flux itself is the single intentional bootstrap exception. It should still be
versioned through the same Nix-owned dependency data as the rest of the cluster,
but applied through the built-in NixOS k3s manifest integration:

```nix
services.k3s.manifests.flux-components.source = renderedFluxComponents;
services.k3s.manifests.flux-sync.source = renderedFluxSync;
```

Prefer official Flux install output generated from a pinned Flux release or
pinned `flux` CLI, such as the equivalent of `flux install --export`, over the
current `fluxcd-community/flux2` Helm chart. That keeps k3s as the bootstrap
applier while avoiding a community Helm wrapper as the root of the GitOps
control plane.

The update path for this exception is:

1. Bump the Nix-owned Flux bootstrap version.
2. Regenerate the Flux controller and sync manifests.
3. Run a check that the generated manifests match the committed/rendered output.
4. Rebuild/switch the k3s host so the NixOS service integration places the new
   manifests in the k3s server manifests directory.
5. Let k3s' deploy controller update Flux; Flux continues reconciling every
   non-bootstrap object.

### Reconciliation layer: Flux

Flux should own all long-running Kubernetes resources after bootstrap:

- cert-manager
- Kyverno
- Multus and related CNI add-ons
- KubeVirt operator and KubeVirt CRs
- CSI, snapshotter, ingress, observability, CI runners
- app workloads such as blog, game servers, and future services

There will still be rare resources that are host files or NixOS service config,
not Kubernetes resources; those stay in NixOS. But if the object is a
Kubernetes resource and Flux can safely reconcile it, the default answer should
be Flux.

### Dependency layer: Nix

Add a Nix-owned cluster dependency registry or generated lock data. This should
cover more than Helm charts: Flux-owned cluster state will also depend on raw
upstream release manifests, controller/bootstrap manifests, and privileged
container images. The exact shape can be chosen during implementation, but the
key rule is that dependency identity is not buried in per-component values.

Component configuration should stay close to the component that owns it. The
registry owns dependency identity and reproducibility:

- Helm chart source, chart name, version, and fixed-output hash
- OCI Helm chart source/ref/digest where practical
- runtime container image repository, tag, and digest where practical
- raw upstream manifest URL/version/hash for projects without a good chart
- Flux bootstrap version, component set, and generated manifest hashes
- high-risk controller/helper image tags and digests, especially privileged
  system components

Possible shape:

```nix
{
  bootstrap.flux = {
    method = "flux-install-manifests";
    version = "2.x.y";
    hash = "sha256-...";
    components = [
      "source-controller"
      "kustomize-controller"
      "helm-controller"
      "notification-controller"
    ];
  };

  cert-manager = {
    repo = "https://charts.jetstack.io";
    chart = "cert-manager";
    version = "v1.20.2";
    hash = "sha256-...";
  };

  kubevirt-operator = {
    kind = "github-release-manifest";
    owner = "kubevirt";
    repo = "kubevirt";
    version = "v1.8.3";
    urlTemplate = "https://github.com/kubevirt/kubevirt/releases/download/${version}/kubevirt-operator.yaml";
    hash = "sha256-...";
  };

  macvtap-cni = {
    kind = "oci-image";
    image = "quay.io/kubevirt/macvtap-cni";
    tag = "v0.13.1";
    digest = "sha256:...";
  };
}
```

Use that data to:

- render and check the Flux bootstrap manifests consumed by
  `services.k3s.manifests`,
- render Flux `HelmRepository` / `OCIRepository` / `HelmRelease` manifests, or
- validate hand-written Flux manifests against Nix-owned pins, and
- build checks that fetch chart artifacts, raw manifests, and selected images
  and fail on hash/digest drift.

For OCI charts, prefer a Flux `OCIRepository` on the cluster side and a Nix
fetch/check path on the repo side. The implementation should account for the
NixOS k3s module's historical limitations around OCI `autoDeployCharts`; this
is another reason not to depend on `autoDeployCharts` as the final Helm
interface.

For privileged or foundational images, prefer digest-only image references or
at least tag-plus-expected-digest validation. Tags such as `v1.2.3` are better
than `latest`, but they are still mutable in principle. Digest-only references
avoid tag drift entirely; tag-plus-digest validation keeps a human-readable tag
while detecting if that tag starts resolving to different content. Digest
validation matters most for host-adjacent or privileged components such as CNI
helpers, storage drivers, and VM operators.

### Update tooling: repo-native first, Renovate optional

Pinning and updating are separate concerns. The registry/checks make dependency
selection reproducible; an updater discovers newer upstream releases and opens a
reviewable PR.

The preferred first implementation is a repo-native updater, because the
authoritative dependency surface is expected to be Nix data rather than Flux
YAML:

```bash
./scripts/update-k3s-deps.sh list
./scripts/update-k3s-deps.sh check
./scripts/update-k3s-deps.sh update cert-manager
./scripts/update-k3s-deps.sh update --all --patch-only
```

Minimum updater responsibilities:

- read the Nix dependency registry,
- discover newer versions from the source type actually in use:
  - Helm repository `index.yaml`,
  - GitHub/Git forge releases for raw manifests,
  - OCI registry tags/digests via a registry client such as `skopeo`,
  - Flux release tags for bootstrap manifests,
- update version/tag/digest fields and fixed-output hashes,
- regenerate committed Flux YAML when YAML is generated from the registry,
- run targeted checks before opening or updating an AGit PR.

Renovate is optional. It can still be valuable later for release discovery,
grouping, scheduling, and changelog links, but only if the chosen authoritative
dependency surface is configured as Renovate's edit target. Avoid the mixed
model where Nix is authoritative while Renovate edits only generated Flux YAML:
the drift check would correctly fail until the Nix registry was updated too.

Choose one update surface per dependency class:

- **Nix registry authoritative:** use a repo-native updater, or Renovate
  regex/custom managers that edit the Nix registry and then regenerate YAML.
- **Flux YAML authoritative:** compatibility/alternative model, not the
  recommended repo target. Let Renovate's native Flux manager edit
  `HelmRelease` / source YAML, and make Nix validate/fetch from committed YAML
  rather than owning separate version fields.
- **Custom updater authoritative:** do not expect Renovate to manage those pins.

For this repo, start with the Nix-registry-authoritative path. It matches the
flake's existing fixed-output dependency style and avoids introducing Renovate
before there is a clear operational need.

### GitOps compatibility rules

The Nix layer must not become an opaque preprocessor that bypasses normal GitOps
review and controller behavior.

- Flux-owned desired state should exist as committed YAML under the watched
  path. If YAML is generated from Nix, commit the rendered output and add a
  check that fails when generated output differs from committed output.
- Flux health and ordering are not automatic just because Flux owns the object.
  Use Flux `Kustomization` boundaries with `dependsOn`, `wait`, and
  `healthChecks` for CRD/controller ordering:
  - cert-manager before `ClusterIssuer` / `Certificate` resources,
  - Multus before `NetworkAttachmentDefinition` consumers,
  - KubeVirt operator/CRDs before the singleton `KubeVirt` CR, then wait for
    that CR to become healthy before CDI/storage/network add-ons and VM
    resources that depend on them,
  - snapshotter/CSI controllers before snapshot classes, storage classes, and
    workloads consuming them.
- Flux should own the operator install and top-level custom resources, not every
  child object an operator creates and reconciles.
- Reviewed YAML diffs remain the default review artifact. Nix checks add
  reproducibility and drift detection; they should not hide the cluster state
  that Flux will reconcile.

## Ranked options

### 1. Flux owns all Helm releases; Nix renders or validates dependency pins

This is the preferred end state.

Pros:

- Idiomatic GitOps: Flux is the single long-running owner of Kubernetes desired
  state.
- Preserves Nix coherence: dependency bumps are explicit and checkable in repo.
- Avoids subjective split-brain boundaries between "platform" and "workload"
  Helm charts.
- Gets Flux prune, drift correction, status, rollback, and uninstall behavior.

Cons:

- Requires adding a render/check convention for cluster manifests.
- Migration has to be staged carefully so Flux does not fight existing k3s
  `HelmChart` releases.

### 2. Flux owns all Helm releases; versions live directly in YAML

This is the most standard Flux-only model.

Pros:

- Simple and familiar to Kubernetes operators.
- No custom Nix rendering path needed.

Cons:

- Chart versions and values drift back together in YAML.
- Weaker fit for this repo's flake/lockfile dependency posture.
- Harder to review chart dependency bumps separately from configuration edits.

### 3. Hybrid: k3s owns bootstrap/platform, Flux owns workloads

This resembles the current setup.

Pros:

- Low migration risk.
- Keeps current fixed-output chart fetches for existing platform charts.

Cons:

- Leaves two Helm owners in the system.
- Keeps subjective boundary debates alive: cert-manager, Kyverno, Multus, CSI,
  and KubeVirt can each be argued as "platform" or "dynamic".
- Does not get Flux lifecycle semantics for the most important add-ons.

This can be a temporary migration state, but it should not be the target.

### 4. k3s `autoDeployCharts` owns all Helm releases

This is least preferred.

Pros:

- Maximizes NixOS-level chart fetch pinning.

Cons:

- Uses a bootstrap/addon controller as the main release system.
- Lacks Flux's prune/drift/rollback model.
- Makes Kubernetes app lifecycle depend on NixOS host rebuilds.
- Keeps Flux artificially limited despite installing it.

## Migration path

### Phase 1: Make dependency pins explicit

- Add a Nix cluster dependency registry for all existing k3s-managed charts,
  raw release manifests, Flux bootstrap inputs, and selected system images.
- Refactor current `autoDeployCharts`, `services.k3s.manifests` fetches, and
  image-tag constants to consume that registry where practical.
- Add checks that verify chart fetches, raw manifest fetches, and selected image
  digests/hashes.
- Add or reserve the repo-native updater interface (`update-k3s-deps`) so
  updates have an explicit path before automation is added.

This does not change runtime ownership yet; it just separates versions from
configuration and creates a stable source of truth.

### Phase 2: Bootstrap Flux from k3s only

- Replace the existing `flux2` `autoDeployCharts` bootstrap with
  `services.k3s.manifests` entries for pinned/generated Flux install manifests
  and Flux sync objects.
- Prefer generated official Flux controller manifests from a pinned Flux
  release/CLI over the community `flux2` Helm chart. The controller manifest
  generation path should be explicit, for example `flux install --export`.
- Generate or render the Git source/sync objects separately, or use the
  equivalent bootstrap export flow, and document which path produces each
  artifact.
- Add a check that regenerates or validates the bootstrap manifests from the
  Nix-owned Flux version.
- Ensure the Flux source points at a monorepo path for cluster state.

### Phase 3: Move platform charts into Flux

Move one release at a time from k3s `autoDeployCharts` to Flux
`HelmRelease`.

Suggested order:

1. cert-manager
2. Kyverno
3. KubeVirt
4. Multus / CNI add-ons
5. CSI / snapshotter / ingress / observability as they are added

For each migration:

- render or write the Flux resources,
- commit the Flux-owned YAML that Flux will reconcile,
- define Flux `Kustomization` ordering and health behavior for CRDs,
  controllers, and dependent custom resources,
- define Helm CRD lifecycle behavior for chart-backed releases before handoff
  (`install.crds` / `upgrade.crds`, or the chart-specific equivalent),
- apply with ownership handoff planned,
- remove the k3s `autoDeployCharts` entry only after Flux is healthy,
- document any uninstall/manual cleanup required because k3s AddOn deletion is
  not a prune operation.

### Phase 4: Make Flux the default for all new cluster work

Plans should stop proposing new `services.k3s.autoDeployCharts` entries. Flux
bootstrap should use `services.k3s.manifests` with Nix-pinned/generated Flux
manifests; new non-bootstrap Kubernetes resources should land under the Flux
watched path by default. New dependency-bearing resources should also add a
registry entry and update-check coverage unless their dependency is already
covered elsewhere.

## Plan-update guidance

Future and active plans should be updated with the following rule:

> If it is Kubernetes desired state and it is not required to bootstrap Flux,
> declare it in the Flux-managed cluster path. Use Nix to pin, render, or verify
> its dependency inputs, and keep the Flux-owned YAML committed and reviewable.

For Flux itself, use the same Nix pin/update mechanism, but render/apply it as
the bootstrap input to `services.k3s.manifests` rather than as a Flux-owned
`HelmRelease` or k3s `autoDeployCharts` entry.

Specific plan implications:

- `llm-notes/wip/k3s-cluster-workloads-plan.md`: keep its dynamic-layer
  direction, but update references that assume platform Helm charts remain
  k3s-owned. Make Flux the owner for future workload and add-on Helm releases.
- `llm-notes/plans/incus-workstation-migration-plan.md`: keep Flux as the owner
  of KubeVirt VM shells, and route CSI / snapshotter / KubeVirt add-on changes
  through Flux rather than k3s `autoDeployCharts`.
- `llm-notes/wip/workload-network-isolation-plan.md`: if more cluster CNI or
  network-policy add-ons are added, they should be Flux-owned after bootstrap,
  even when they are platform substrate.
- Historical `done/` plans should generally remain historical, but may get a
  short forward-looking note if they would otherwise mislead readers into
  treating k3s `autoDeployCharts` as the intended final state.
