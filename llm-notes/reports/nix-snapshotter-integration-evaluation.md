# nix-snapshotter Integration Evaluation

Date: 2026-06-25

## Executive Summary

`pdtpartners/nix-snapshotter` is a good fit for one specific pressure point in
this repo: **Nix-built Kubernetes workload images**, especially Woodpecker CI
build-step images that are already created from Nix closures. It is not a
general replacement for the Forgejo container registry, KubeVirt containerDisk
publication, or normal third-party controller image pulls.

Recommendation: **pilot it, but do not cut the cluster over wholesale yet.**
Start with a trivial pod image on erebonia, then immediately test a KubeVirt
containerDisk image before touching production dev-machine flows. Treat it as a
node-runtime feature gated behind explicit tests. If the pilot proves clean with
k3s, gVisor, KubeVirt, and image GC, then use it for Nix-native workload images.
Keep registry-backed OCI images for the dev-machine devcontainer image,
third-party controllers, and any workload that must remain portable outside a
nix-snapshotter-enabled containerd node.

Important nuance: the dev-machine base image publication path is a real pain
point, and nix-snapshotter might help there. It is not rejected because it is
known not to work. It is placed after an ordinary-pod pilot because KubeVirt
containerDisks add another layer of behavior to validate: the VM disk image is
consumed through KubeVirt's containerDisk init/launcher flow, not by directly
executing a normal container root filesystem. If that proof passes, replacing
`publish-base` with a Nix-store/binary-cache path would be one of the highest
value follow-ups.

## Upstream Snapshot

Upstream: <https://github.com/pdtpartners/nix-snapshotter>

Observed on 2026-06-25:

- Latest release: `v0.4.0`, published 2026-02-24.
- Main branch head: `8e875fb8eeb28947e2b4c3e7552f511d8d1f405a`, dated
  2026-02-24.
- The project provides a containerd snapshotter plugin, a CRI image service for
  Kubernetes, NixOS/Home Manager modules, k3s integration modules, tests, and a
  `pkgs.nix-snapshotter.buildImage` helper.
- The README describes the core value: container content can come from a Nix
  store or binary cache instead of OCI layer downloads, while remaining
  compatible with normal non-Nix images.
- The architecture docs say the snapshotter creates Nix GC roots for store
  paths referenced by containerd snapshots. Containerd GC removes those roots
  when snapshots disappear; Nix GC can then collect unreferenced paths.
- Kubernetes `nix:0/nix/store/...-nix-image-*.tar` image references require
  kubelet to use nix-snapshotter's CRI ImageService, not just the default
  containerd image service.

Risk signals:

- Open issues include kata-container support, k3s/NVIDIA compatibility,
  multi-arch image support, rootless k3s support, and NixOS service/machine
  config usage. Those are not automatic blockers here, but they overlap with
  this repo's use of k3s, gVisor, KubeVirt, and future multi-node plans.
- Upstream k3s support has moved forward since the original nix-snapshotter
  discussions. k3s now has closed work for bundled-containerd nix-snapshotter
  support, including backports tracked for `v1.34.6+k3s1` and
  `v1.33.10+k3s1`. Current k3s templates contain explicit `snapshotter = "nix"`
  handling and nix image-service config. This makes the k3s part less
  speculative than the KubeVirt containerDisk part.
- The upstream nix-snapshotter NixOS module can wire k3s to external containerd
  with `--container-runtime-endpoint` and `--image-service-endpoint`, but this
  repo currently relies on k3s' embedded containerd plus local config drop-ins.

Sources:

- README: <https://github.com/pdtpartners/nix-snapshotter>
- Architecture: <https://github.com/pdtpartners/nix-snapshotter/blob/main/docs/architecture.md>
- Package interface: <https://github.com/pdtpartners/nix-snapshotter/blob/main/package.nix>
- NixOS/k3s modules: <https://github.com/pdtpartners/nix-snapshotter/tree/main/modules>
- Issues: <https://github.com/pdtpartners/nix-snapshotter/issues>
- k3s bundled-containerd support: <https://github.com/k3s-io/k3s/issues/13733>
- k3s `v1.34` backport: <https://github.com/k3s-io/k3s/issues/13739>
- k3s containerd template: <https://github.com/k3s-io/k3s/blob/main/pkg/agent/templates/templates.go>
- KubeVirt containerDisk docs: <https://kubevirt.io/user-guide/storage/disks_and_volumes/>
- KubeVirt containerDisk implementation: <https://github.com/kubevirt/kubevirt/blob/main/pkg/container-disk/container-disk.go>

## Online Evidence

I found public evidence for **nix-snapshotter with k3s**, but not for
**nix-snapshotter with KubeVirt containerDisk**.

What is confirmed:

- k3s has upstream/closed support work for `--snapshotter=nix` with bundled
  containerd. The current k3s templates include nix snapshotter blocks,
  `disable_snapshot_annotations = false`, image-service enablement, and unpack
  config for `linux/amd64` and `linux/arm64`.
- nix-snapshotter's own examples include declarative Kubernetes resources that
  use `resolvedByNix = true` and `image = "nix:0${image}"`.
- A public homelab writeup describes using k3s + nix-snapshotter to build custom
  service images from Nix derivations and place the resulting Nix-store image
  references in manifests.
- One upstream issue reports that `k3s + nix-snapshotter` worked by itself, even
  though combining it with NVIDIA runtime setup had runtime-registration issues.

What I did **not** find:

- No public working example of `nix:0/nix/store/...` as a KubeVirt
  `containerDisk.image`.
- No issue report clearly confirming or denying KubeVirt containerDisk behavior
  with nix-snapshotter.

Why it is still plausible:

- KubeVirt containerDisk ultimately uses Kubernetes image pulling for generated
  virt-launcher/init containers. KubeVirt's implementation sets the generated
  container `Image` from `volume.ContainerDisk.Image`.
- KubeVirt's documented containerDisk format is simple: a scratch-like image
  containing a raw or qcow2 disk under `/disk`, readable by UID 107.

Conclusion: **the k3s layer has enough evidence to justify a real pilot; the
KubeVirt containerDisk layer needs a direct local proof.** The first
containerDisk proof should be treated as an experiment, not a migration.

## Current Repo Image-Management Shape

The current repo has several distinct image flows. They should not be collapsed
into one mechanism.

### k3s Platform And CI Images

`hosts/erebonia/k3s/woodpecker-images.nix` defines:

- pulled third-party archives via `pkgs.dockerTools.pullImage`:
  `woodpecker-agent`, `woodpeckerci/plugin-git`, and `busybox`;
- a modified plugin-git image with internal CA material;
- `localhost/dotfiles-ci-nix:0.1.3`, built with
  `pkgs.dockerTools.buildLayeredImageWithNixDb`;
- `localhost/ci-worker-base:latest`, a KubeVirt containerDisk derived from
  `packages/ci-worker-image`.

`hosts/erebonia/k3s/woodpecker-ci.nix` currently preloads archives through
`services.k3s.images` and a separate `woodpecker-ci-import-images` oneshot. The
separate oneshot exists because the CI worker KubeVirt containerDisk is large
and needs explicit import into k3s containerd.

This path solves registry-pull-secret avoidance and makes CI startup mostly
node-local, but it still duplicates Nix closure content into OCI archives and
containerd image storage.

### Dev-Machine Images

`packages/dev-machine-image` builds a bootable qcow2 and wraps it as a KubeVirt
containerDisk OCI image. `packages/dev-machine-dev-image` builds the inner
DevPod devcontainer image. The `dev-machine` wrapper publishes these to the
Forgejo registry with `skopeo`.

This is intentionally registry-backed:

- the operator wrapper can inspect/publish images;
- KubeVirt `containerDisk.image` naturally consumes an OCI image ref;
- the dev-machine VM later runs rootful Podman inside the VM for the
  devcontainer, not the host k3s containerd snapshotter.

`nix-snapshotter` does not automatically improve that inner Podman runtime.

It may improve the **base VM containerDisk** path. KubeVirt documents
containerDisk as a way to store and distribute VM disks in a container image;
the disk must live under `/disk`, and the image is pulled to the local node that
runs the VM. That is close enough to nix-snapshotter's model to justify a
proof-of-concept:

- build `packages/dev-machine-image` with `pkgs.nix-snapshotter.buildImage`
  instead of `pkgs.dockerTools.streamLayeredImage`;
- set `resolvedByNix = true`;
- point a test VM's `containerDisk.image` at `nix:0/nix/store/...`;
- ensure the qcow2 closure is available to erebonia through Attic or a direct
  `nix copy`, not through a Forgejo registry push.

The expected win is removal of the large `skopeo copy`/registry-publish step for
base image iteration. The expected non-win is dedupe inside the qcow2 itself:
the qcow2 remains a large monolithic store path, so nix-snapshotter avoids OCI
layer/import duplication but does not make the VM disk content package-granular.

It does **not** materially improve `packages/dev-machine-dev-image` as long as
that image is pulled by rootful Podman inside the guest VM. nix-snapshotter is a
containerd snapshotter; Podman will not consume `nix:0` references.

### Third-Party Controllers And Flux Direction

The cluster ownership direction in
`llm-notes/reports/k3s-flux-helm-ownership.md` is:

> NixOS/k3s bootstraps the cluster and Flux. Flux owns Kubernetes desired state.
> Nix owns dependency pins, rendering, and validation.

Most controller images should still be ordinary OCI images pinned by tag/digest
and reconciled by Flux. nix-snapshotter should not become a reason to move
normal add-on ownership back into NixOS/k3s.

## What Pain Points It Would Solve

### 1. Duplicate Storage For Nix-Built Images

Today, `dotfiles-ci-nix` and the CI worker image are Nix products converted
into OCI image archives and then imported into containerd. That creates two
stores of truth for the same bytes:

- Nix store paths and binary-cache objects;
- OCI layer archives and containerd snapshots.

nix-snapshotter can let containerd mount the Nix closure directly and keep GC
roots for the store paths it needs. For Nix-built build-step images, this is the
cleanest conceptual fit.

### 2. Faster Iteration For Nix-Native CI Images

The current `dotfiles-ci-nix` flow requires rebuilding an image archive,
importing it into containerd, keeping tags in sync, and pruning old tags.
nix-snapshotter would let a pod image reference point at a Nix-built image
artifact, with content fetched from the Nix binary cache or already present in
the node store.

That reduces the "build Nix closure, turn it into OCI layers, import layers"
cycle for Nix-native images.

### 3. Better Store-Level Deduplication

Multiple Nix-built workload images can share store paths at package
granularity. OCI layering heuristics can duplicate common paths or group them
in ways that do not match actual closure sharing. nix-snapshotter moves
deduplication back to the Nix store.

This is attractive for CI, because future build images are likely to share
large toolchain closures.

### 4. No Registry Requirement For Some Internal Images

For `resolvedByNix = true` images, Kubernetes can use an image reference like
`nix:0/nix/store/...-nix-image-foo.tar`. That can remove registry publication
from some internal Nix-native workloads.

This is useful only when every eligible node has nix-snapshotter and can
substitute or build the referenced store path.

## What It Would Supplement

### `services.k3s.images` Preload

It can supplement and partially replace `services.k3s.images` for **Nix-built
images**. For example, `localhost/dotfiles-ci-nix:0.1.3` is a plausible pilot
candidate.

Keep `services.k3s.images` or ordinary registry pulls for third-party images
unless there is a clear reason to wrap them.

### `woodpecker-ci-import-images.service`

For Nix-native build-step images, nix-snapshotter can eliminate some manual
`k3s ctr images import` work.

For the KubeVirt CI worker containerDisk, be more cautious. KubeVirt expects a
containerDisk image with `/disk/boot.qcow2`; it should be plausible to represent
that image through nix-snapshotter, but this should be treated as a second phase
after validating ordinary pods. The same proof would inform the dev-machine
base image path.

### `dev-machine publish-base`

This is the highest-value dev-machine-specific target if the KubeVirt
containerDisk proof succeeds.

Potential replacement shape:

- `dev-machine publish-base` becomes `dev-machine realize-base` or disappears
  from the normal path.
- The wrapper builds `.#dev-machine-image`.
- The wrapper pushes/copies the Nix closure to the node-visible binary cache
  instead of pushing an OCI archive to Forgejo.
- The generated VM manifest uses the resulting `nix:0/nix/store/...` image ref.

Tradeoff: this moves distribution from "registry has the image tag" to "Attic
or the node Nix store has the image closure." That is consistent with this
repo's Nix-first direction, but the wrapper must make cache/copy failures clear
or it will just replace one publish failure mode with another.

### Forgejo Registry

It supplements the registry. It should not replace it.

Forgejo registry remains the right home for:

- dev-machine devcontainer image;
- images consumed by non-nix-snapshotter runtimes;
- images that should be inspectable and pullable by standard tools;
- third-party mirrors or cached controller images.

The dev-machine base VM image is the deliberate exception to keep investigating:
if KubeVirt accepts a nix-snapshotter `containerDisk.image`, moving the base VM
image off Forgejo would remove one of the dev-machine wrapper's larger pain
points.

### Attic / Nix Binary Cache

It increases the value of the binary cache. Container startup for Nix-native
images becomes a Nix substitution problem, so Attic availability and cache
population matter more for cluster workload startup.

This aligns with the repo's CI/CD direction, but it also means a cold node
could try to build image closures locally unless substituters are configured and
trusted correctly.

## What It Would Replace

Recommended replacements are narrow:

- Replace archive import and tag-prune logic for selected Nix-native CI build
  images after a pilot.
- Replace some registry-publish steps for internal, single-cluster,
  Nix-native workloads that do not need standard OCI portability.

Do not replace yet:

- KubeVirt/dev-machine base image registry publication before a containerDisk
  proof.
- Forgejo registry as the image distribution and inspection interface.
- Flux ownership of Kubernetes workloads.
- Digest-pinned third-party controller images.
- `dockerTools.pullImage` for third-party images where the source of truth is
  already an OCI registry.

## Integration Options

### Option A: Minimal Embedded-k3s Integration

Keep k3s' embedded containerd and add nix-snapshotter as a sidecar systemd
service plus k3s/containerd drop-ins.

Required pieces:

- Add `nix-snapshotter` as a flake input and overlay, or package it locally from
  the input.
- Enable `services.nix-snapshotter`.
- Configure k3s to use snapshotter `nix` for image unpacking.
- Configure kubelet/k3s with `--image-service-endpoint
  unix:///run/nix-snapshotter/nix-snapshotter.sock` for `nix:0...` references.
- Ensure embedded containerd loads the nix snapshotter plugin or proxies to it.
- Preserve this repo's existing runtime drop-ins for `runsc` and `runc-kvm`.
- Add restart triggers when nix-snapshotter or containerd config changes.

Pros:

- Least disruptive if it works with the current k3s package.
- Keeps the repo's current all-in-one k3s shape.

Cons:

- This is still compatibility-sensitive because it touches kubelet image pulls
  and embedded containerd config.
- This repo currently uses `pkgs.k3s_1_36`; verify the nixpkgs package includes
  the k3s bundled-containerd nix-snapshotter support before relying on
  `--snapshotter=nix`.
- Upstream release `v0.4.0` fixed CRI API compatibility for Kubernetes
  `>= 1.34`, but the local k3s package still needs real validation.

### Option B: External Containerd For k3s

Run NixOS-managed containerd and point k3s at it using
`--container-runtime-endpoint unix:///run/containerd/containerd.sock`, matching
upstream's module style more closely.

Pros:

- Cleaner integration with upstream's NixOS module.
- Containerd config is more directly owned by NixOS instead of k3s-generated
  embedded config.

Cons:

- Bigger platform change. It touches the cluster's core runtime, existing CNI
  paths, runtime classes, gVisor registration, KubeVirt, and CI.
- Not justified just to improve a handful of CI images.

Recommendation: do **not** start here.

### Option C: No Runtime Integration, Only Use `buildImage` For Registry Images

Use `pkgs.nix-snapshotter.buildImage` to produce OCI-compatible manifests and
push them to Forgejo, but do not enable the host snapshotter.

Pros:

- Smaller packaging experiment.

Cons:

- Loses the main benefit. Without nix-snapshotter-enabled containerd, native
  nix-snapshotter images are not portable to ordinary runtimes.
- For normal OCI images, `dockerTools`/`nix2container` remain better understood
  in this repo.

Recommendation: only useful as a build-interface experiment, not as the main
integration.

## Recommended Pilot

Pilot scope: one trivial pod image, one KubeVirt containerDisk proof, then one
low-risk Woodpecker build-step image.

Candidate: a new `dotfiles-ci-nix` variant, not the current production tag at
first.

Implementation sketch:

1. Add `nix-snapshotter` as a flake input following this repo's `nixpkgs`.
2. Import only the needed overlay/module on erebonia.
3. Add an opt-in `hosts/erebonia/k3s/nix-snapshotter.nix` module.
4. Configure nix-snapshotter and k3s without changing the default runtime
   classes.
5. Build a minimal `pkgs.nix-snapshotter.buildImage` test image with
   `resolvedByNix = true`, such as a `hello` or tiny CI smoke image.
6. Apply a one-shot test Pod through `services.k3s.manifests` or a VM test,
   using a `nix:0/nix/store/...` image reference.
7. Build a scratch-style KubeVirt containerDisk test image with
   `pkgs.nix-snapshotter.buildImage`, placing a small qcow2 under `/disk` with
   UID/GID readable for KubeVirt's qemu user.
8. Apply a one-shot test VMI/VM whose `containerDisk.image` is the resulting
   `nix:0/nix/store/...` reference.
9. Validate:
   - pod starts under ordinary runc;
   - pod starts under `runsc` if build pods keep using gVisor;
   - the KubeVirt test VM reaches Running;
   - the KubeVirt test VM can read/boot the qcow2;
   - normal registry images still pull;
   - existing Woodpecker agent and KubeVirt workloads still start;
   - containerd image GC and Nix GC do not remove running image closures;
   - rollback restores the previous k3s runtime behavior.
10. Only after that, move a non-critical Woodpecker pipeline lane to the
   nix-snapshotter CI image.

Exit criteria for broader use:

- No regression in existing Woodpecker quick-preflight.
- No regression in KubeVirt VM startup.
- A nix-snapshotter-backed KubeVirt containerDisk works, or the repo explicitly
  limits nix-snapshotter to pod workloads.
- `runsc` build pods work with nix-snapshotter images or the repo explicitly
  keeps nix-snapshotter images on runc-only lanes.
- The Nix store closure is substituted from the intended cache, not built
  unexpectedly on the node for routine image pulls.
- GC behavior is understood and documented.

## Compatibility Questions To Resolve Before Production Use

1. **k3s embedded containerd support.** Verify that this repo's
   `pkgs.k3s_1_36` contains the upstream bundled-containerd nix-snapshotter
   support and that the NixOS module wiring composes with k3s' embedded
   containerd. Avoid an external-containerd migration unless embedded k3s fails
   the pilot.

2. **RuntimeClass interaction.** The repo uses `runsc` for restricted CI pods
   and `runc-kvm` for KVM-oriented workloads. Upstream has an open kata support
   issue; even though this repo's immediate CI build pods use gVisor rather than
   kata, RuntimeClass coverage must be tested rather than assumed.

3. **KubeVirt containerDisk behavior.** I found no public example of
   nix-snapshotter with `containerDisk.image`. A containerDisk is an OCI image
   used by generated KubeVirt pods, but it is not just a normal process root
   filesystem. Validate this separately before replacing `ci-worker-base` imports
   or `dev-machine publish-base`.

4. **Multi-node future.** If k3s grows beyond single-node erebonia, every node
   eligible for Nix-native pods must have the same nix-snapshotter integration,
   Nix substituter trust, and store GC policy.

5. **Image reference ergonomics.** `nix:0/nix/store/...` image references are
   exact and declarative but not normal registry refs. Flux/Kustomize rendering
   can handle them, but operational debugging and policy allowlists need updates.

6. **Kyverno policy.** `hosts/erebonia/k3s/kyverno.nix` currently allowlists
   specific preloaded CI image names. A nix-snapshotter pilot needs either a
   tightly scoped `nix:0/nix/store/...` allow rule or a separate namespace/lane.

7. **Attic dependency.** If a referenced closure is absent locally, startup
   depends on Nix substitution or local build. The node should not perform
   surprise expensive builds for routine pod starts.

## Security And Operations Impact

Security positives:

- Fewer mutable registry-publish credentials needed for internal Nix-native
  images.
- Image content can inherit Nix store signature/substituter trust instead of
  depending only on registry digest semantics.
- Store-level dedupe reduces pressure to maintain large local imported-image
  state.

Security concerns:

- The node runtime becomes more complex: kubelet image handling now depends on
  an additional privileged systemd service and containerd plugin path.
- `nix:0` references are only meaningful on configured nodes; a policy or
  scheduling mistake fails at runtime.
- If local builds are allowed during image pulls, a workload start can become a
  build execution path on the node. Prefer cache-hit-only operation for routine
  cluster images.

Operational positives:

- Less image import/prune code for Nix-built CI images.
- Better alignment with this repo's Nix-first build model.
- Cleaner future for multiple internal build images that share toolchains.

Operational costs:

- More complicated k3s/containerd debugging.
- Need new smoke tests.
- Need clearer GC runbooks.
- Need policy updates for non-registry image refs.

## Overall Worthwhile?

Yes, but only as a **targeted supplement**.

It is worthwhile for this repo if the goal is to reduce duplication and
publication/import friction for Nix-native Kubernetes workloads. The k3s path
now has enough upstream evidence to make a pilot reasonable. The largest
possible local win is the dev-machine base VM `containerDisk` path, but that
specific use remains unproven publicly and should be tested before changing the
wrapper's normal behavior. It is not worthwhile as a broad replacement for the
current k8s image-management design because much of the repo's image surface is
third-party OCI or the dev-machine devcontainer registry workflow.

The practical recommendation is:

1. Keep the current Forgejo registry and `services.k3s.images` paths as the
   stable baseline.
2. Add nix-snapshotter behind a focused erebonia/k3s module only after current
   CI/KubeVirt behavior is green.
3. Pilot one runc/gVisor pod image.
4. Immediately pilot one KubeVirt containerDisk image.
5. If the containerDisk proof passes, prototype a `publish-base` replacement
   that distributes the Nix closure through Attic or `nix copy` and renders a
   `nix:0/nix/store/...` `containerDisk.image`.
6. Expand to `dotfiles-ci-nix` if the pod/runtime pilot passes.
7. Re-evaluate `ci-worker-base` only after ordinary pod images and a small
   containerDisk are proven.

If the pilot requires external-containerd migration or k3s patching beyond a
small, maintainable module, defer adoption. If the pod pilot succeeds but the
containerDisk pilot fails, still consider nix-snapshotter for CI pod images, but
leave `dev-machine publish-base` on the Forgejo registry path.
