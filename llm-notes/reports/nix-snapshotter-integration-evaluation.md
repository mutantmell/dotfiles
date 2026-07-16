# nix-snapshotter Integration Evaluation

Date: 2026-07-16 (updated from the original 2026-06-25 evaluation)

## Executive Summary

`pdtpartners/nix-snapshotter` is a good fit for one specific pressure point in
this repo: **Nix-built Kubernetes workload images**, especially Woodpecker CI
build-step images that are already created from Nix closures. It is not a
general replacement for the Forgejo container registry, KubeVirt containerDisk
publication, or normal third-party controller image pulls.

Recommendation: **do not enable it on production erebonia yet.** Keep the pilot
design, but first reproduce or rule out upstream issue #183 in a NixOS VM using
the repo's exact `k3s 1.36.2+k3s1`. That issue reports permanent container-create
failures for file-valued Nix store paths with the bundled k3s integration, and
was opened on 2026-07-14 against the same k3s version this flake currently
evaluates. If that blocker is fixed or the repo can constrain images to avoid
it, start with a trivial pod image, then test a KubeVirt containerDisk before
touching production dev-machine flows. Treat it as a node-runtime feature gated
behind explicit tests. If the pilot proves clean with k3s, gVisor, KubeVirt, and
image GC, then use it for selected Nix-native workload images.
Keep ordinary OCI images for the dev-machine devcontainer, third-party
controllers, and any workload that must remain portable outside a
nix-snapshotter-enabled containerd node. The devcontainer image can be loaded
directly into guest Podman under an immutable local tag; ordinary OCI format is
required there, but registry publication is optional.

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

Rechecked on 2026-07-16:

- There has been no new release or main-branch commit: `v0.4.0` and commit
  `8e875fb8eeb28947e2b4c3e7552f511d8d1f405a` remain current.
- Erebonia's flake evaluates `pkgs.k3s_1_36` to `1.36.2+k3s1`. That release has
  the bundled-containerd nix snapshotter configuration, so the old question of
  whether the local k3s binary contains the integration is resolved: it does.
- Upstream nix-snapshotter issue #183 reports a regression with exactly
  `k3s v1.36.2+k3s1`: images can fail container creation with `not a directory`,
  consistently when a file-valued store path is in the closure and reportedly
  sometimes in less obvious cases. The reporter says the same image works with
  k3s 1.35.6 and nix-snapshotter's non-bundled test VM. This is a production
  blocker until reproduced and fixed or convincingly avoided.
- Issue #179 also tracks a checkpoint-image lookup failure in the embedded k3s
  integration and asks for a `v0.4.1` release. No such release exists yet.
- There is still no public KubeVirt containerDisk integration example or
  upstream test. The local proof remains necessary.

Sources:

- README: <https://github.com/pdtpartners/nix-snapshotter>
- Architecture: <https://github.com/pdtpartners/nix-snapshotter/blob/main/docs/architecture.md>
- Package interface: <https://github.com/pdtpartners/nix-snapshotter/blob/main/package.nix>
- NixOS/k3s modules: <https://github.com/pdtpartners/nix-snapshotter/tree/main/modules>
- Issues: <https://github.com/pdtpartners/nix-snapshotter/issues>
- k3s bundled-containerd support: <https://github.com/k3s-io/k3s/issues/13733>
- k3s `v1.34` backport: <https://github.com/k3s-io/k3s/issues/13739>
- k3s containerd template: <https://github.com/k3s-io/k3s/blob/main/pkg/agent/templates/templates.go>
- k3s server runtime options: <https://docs.k3s.io/cli/server>
- k3s 1.36 regression: <https://github.com/pdtpartners/nix-snapshotter/issues/183>
- embedded-integration checkpoint bug: <https://github.com/pdtpartners/nix-snapshotter/issues/179>
- KubeVirt containerDisk docs: <https://kubevirt.io/user-guide/storage/disks_and_volumes/>
- KubeVirt containerDisk implementation: <https://github.com/kubevirt/kubevirt/blob/main/pkg/container-disk/container-disk.go>
- DevPod provider model: <https://devpod.sh/docs/developing-providers/quickstart>
- DevPod Docker/Kubernetes drivers: <https://devpod.sh/docs/developing-providers/driver>
- DevPod provider options: <https://devpod.sh/docs/developing-providers/options>
- DevPod devcontainer environment substitution: <https://devpod.sh/docs/developing-in-workspaces/environment-variables-in-devcontainer-json>

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

This is currently registry-backed:

- the operator wrapper can inspect/publish images;
- KubeVirt `containerDisk.image` naturally consumes an OCI image ref;
- the dev-machine VM later runs rootful Podman inside the VM for the
  devcontainer, not the host k3s containerd snapshotter.

`nix-snapshotter` does not automatically improve that inner Podman runtime, but
the inner image does **not** therefore have to remain registry-backed. DevPod's
Docker driver first asks its configured Docker-compatible CLI to inspect the
image locally. In this repo that CLI is the `podman-rootful` wrapper. A
Nix-built OCI stream can therefore be loaded into the VM's rootful Podman store
under an immutable, content-derived local tag before `devpod up`; DevPod can
then inspect and run it without a registry pull.

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

It does **not** materially improve `packages/dev-machine-dev-image` itself.
nix-snapshotter is a containerd snapshotter; Podman will not consume `nix:0`
references. The registry-free alternative for this image is a separate local
preload path:

1. Build `.#dev-machine-dev-image` with the existing `streamLayeredImage` or a
   similarly portable OCI builder.
2. After the VM and Podman socket are ready, execute or stream the image into
   `podman-rootful load` inside the VM.
3. Tag it as `localhost/dev-machine-dev:<content-derived-id>` and verify
   `podman-rootful image exists` before starting DevPod.
4. Change the devcontainer image to `${localEnv:DEV_MACHINE_IMAGE}` (with a
   suitable default during migration) and pass that variable to the remote
   DevPod agent through the SSH/provider environment.

The base VM already contains the dev-tool closure that the inner image uses,
because `/nix` is later bind-mounted into the devcontainer. A refined preload
could therefore put only the image-stream derivation and its generation tools
in the base-system closure and generate/load the layers inside the VM. That can
avoid registry publication and retransmitting most inputs. Podman will still
materialize OCI layers in scratch storage, so this does not provide
nix-snapshotter's package-granular deduplication.

### Actual DevPod Constraint

The constraint is the **driver**, not the image's distribution location.
DevPod's normal Docker driver needs an image that its configured CLI can
inspect and use for Docker-compatible container creation. A plain Nix store
directory, a `streamLayeredImage` output script, or a `docker-archive:`/`oci:`
transport path is an import source, not normally a valid image name for that
API. Loading it into Podman's containers/storage supplies the required image
configuration, metadata, layers, and image identity.

DevPod documents only Docker and Kubernetes agent drivers; it does not document
a provider extension point for an arbitrary third driver. Translating a Nix
store reference into `podman run --rootfs` or another rootfs/overlay scheme
would therefore require changing DevPod, relying on an unsupported internal
interface, or supplying a Docker-compatible CLI replacement that reimplements
the relevant image and container operations. None is justified while a local
OCI preload preserves standard devcontainer and Podman semantics.

### Custom KubeVirt DevPod Provider

A custom **machine provider** is a good longer-term fit, although it is not
required to prove local image preload. DevPod providers natively model
`create`, `delete`, `start`, `stop`, `status`, and `command`; a KubeVirt
provider could replace the wrapper's dynamically created per-machine SSH
providers and own the ordered transaction:

1. allocate the slot/IP/MAC;
2. realize the base image and create the KubeVirt VM;
3. wait for VM readiness, guest-agent connection, and SSH;
4. realize and preload the immutable inner image into rootful Podman;
5. expose its ref to the DevPod agent;
6. let the agent use the normal Docker driver with
   `/run/current-system/sw/bin/podman-rootful`;
7. retain operator-side credential injection and explicit rescue/delete
   behavior.

This should remain a KubeVirt **machine provider plus in-VM Docker driver**. Do
not switch the workspace to DevPod's Kubernetes driver: running the
devcontainer directly as a pod would bypass the VM security boundary and the
VM-host Nix daemon, `/dev/kvm`, uid-range sandbox, and VLAN-51 runtime contract.

The provider must also avoid generic inactivity-driven stop semantics at
first. Podman storage and the workspace live on KubeVirt `emptyDisk`; stopping
or recreating the VMI can discard that mutable state. Preserve the current
explicit `down`/`rescue` model until scratch becomes persistent or loss on stop
is an intentional contract.

### Third-Party Controllers And Flux Direction

The cluster ownership direction in
`llm-notes/reports/k3s-flux-helm-ownership.md` is:

> NixOS/k3s bootstraps the cluster and Flux. Flux owns Kubernetes desired state.
> Nix owns dependency pins, rendering, and validation.

Most controller images should still be ordinary OCI images pinned by tag/digest
and reconciled by Flux. nix-snapshotter should not become a reason to move
normal add-on ownership back into NixOS/k3s.

## Image Pinning: What It Does And Does Not Fix

The repo uses the word "pinning" for several different guarantees. The
distinction matters because nix-snapshotter helps only some of them.

| Current path | Actual pin today | Effect of nix-snapshotter |
| --- | --- | --- |
| Woodpecker agent, plugin-git, busybox in `woodpecker-images.nix` | Upstream OCI digest plus Nix fixed-output hash; a friendly local tag is applied after fetching | No improvement. Keep `dockerTools.pullImage`: it verifies third-party registry content and remains portable. |
| `dotfiles-ci-nix` | Flake inputs pin contents, but Kubernetes uses mutable node-local tag `0.1.3`; operators must bump and prune tags | A `resolvedByNix` store-path reference would make identity immutable and remove manual tag bump/prune work after the runtime blocker is cleared. |
| `ci-worker-base` | Flake pins build inputs, but KubeVirt uses node-local `localhost/ci-worker-base:latest` imported by a custom oneshot | Could replace the mutable tag/import with an immutable Nix store reference, but only if the unproven KubeVirt containerDisk pilot succeeds. |
| Dev-machine base VM | Flake pins build inputs, but wrapper publishes `dev-machine-base:latest`; KubeVirt uses `Always` | Could give the strongest local benefit: an exact store reference and no registry push. It does not make the monolithic qcow2 package-granular. Requires the same containerDisk proof. |
| Dev-machine inner devcontainer | Flake pins build inputs, but `.devcontainer/devcontainer.json` names `dev-machine-dev:latest` | No direct nix-snapshotter help because rootful Podman consumes it. It need not remain registry-backed: preload the Nix-built OCI stream into guest Podman under an immutable content-derived local tag and point DevPod at that tag. |
| KubeVirt/operator/platform images | Release/FOD pins manifests; the operator controls its component image references | Not a suitable target. Keep normal OCI/digest and operator ownership. |

Consequently, nix-snapshotter is **not a general solution to image pinning**.
It can turn selected Nix-native Kubernetes image identities into immutable Nix
store paths. It neither replaces the third-party `imageDigest`/FOD checks nor
directly pins the Podman-consumed devcontainer image; that separate preload path
gets immutability from its Nix-derived local OCI tag. nix-snapshotter also
changes the trust and availability dependency from an OCI registry/digest to
the Nix store and its configured signed substituters.

There is a separate correctness issue in the current dev-machine workflow:
both published image names are mutable `:latest` tags. `up --rebuild` pushes
both, but an ordinary `up` checks only whether the base tag exists and does not
republish the dev image; `.devcontainer/devcontainer.json` nevertheless pulls
the dev image by `:latest`. nix-snapshotter could eliminate that ambiguity only
for the base image. Independently of adopting nix-snapshotter, the dev image
should use an immutable digest/content-derived identity. The preferred local
design is to preload that identity into guest Podman and inject the chosen ref
through `${localEnv:DEV_MACHINE_IMAGE}`; publishing the same identity to
Forgejo remains an optional portability/cache path rather than a requirement.

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

- dev-machine devcontainer images that should be portable or shared without
  per-VM local realization (but not necessarily the normal local path);
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

Separately from nix-snapshotter, replace the inner devcontainer's mutable
registry `:latest` workflow with local immutable Podman preload after a focused
proof. This is an image-realization change, not a k3s runtime integration.

## Integration Options

### Option A: Minimal Embedded-k3s Integration

Keep k3s' embedded containerd and use its bundled nix-snapshotter integration.

Required pieces once issue #183 is resolved:

- Add `nix-snapshotter` as a flake input and overlay, or package it locally from
  the input.
- Use the upstream overlay/package to build images. k3s 1.36 already bundles
  the snapshotter/image-service implementation; do not also introduce a second
  external snapshotter service unless a test demonstrates that it is needed.
- Configure k3s with `--snapshotter=nix`. Its generated containerd v3 template
  already selects the nix snapshotter, enables the embedded image service, and
  installs amd64/arm64 unpack configuration.
- Preserve this repo's existing runtime drop-ins for `runsc` and `runc-kvm`.
- Add restart triggers for the relevant k3s/runtime configuration changes.

Pros:

- Least disruptive and aligned with the integration shipped by the current k3s
  package.
- Keeps the repo's current all-in-one k3s shape.

Cons:

- This is still compatibility-sensitive because it changes the node's default
  snapshotter and image-pull path.
- The current `1.36.2+k3s1` integration is affected by the unresolved failure
  reported in issue #183, so presence of upstream support is not the same as
  production readiness.
- Upstream release `v0.4.0` fixed CRI API compatibility for Kubernetes
  `>= 1.34`, but the local k3s package still needs real validation.

### Option B: External Containerd For k3s

Run NixOS-managed containerd and point k3s at it using
`--container-runtime-endpoint unix:///run/containerd/containerd.sock` and the
appropriate `--image-service-endpoint`. k3s officially supports these flags and
disables its embedded runtime/image service when they are used. The reporter of
issue #183 also says the affected images work in nix-snapshotter's non-bundled
test VM, so this is a plausible fallback to test, not a confirmed fix for this
repo.

Pros:

- Direct integration with nix-snapshotter's external-containerd NixOS module.
- Containerd config is more directly owned by NixOS instead of k3s-generated
  embedded config.
- May avoid a defect specific to k3s's bundled implementation.

Cons:

- This is an officially supported k3s escape hatch, but not its normal
  integrated architecture. NixOS would now own CRI compatibility, service
  ordering, upgrades, recovery, and runtime configuration that k3s otherwise
  coordinates.
- It must reproduce k3s-specific CNI paths, sandbox/registry configuration,
  `runsc` and `runc-kvm` registration, and image GC behavior.
- This repo's `services.k3s.images`, `k3s ctr`, `k3s crictl`, custom image
  import/prune services, KubeVirt, and Woodpecker flows all assume the embedded
  runtime or its socket conventions and need migration tests.
- It introduces a containerd/k3s version-skew boundary and is not justified
  solely to improve a handful of CI images or work around one unconfirmed local
  regression.

Recommendation: do **not** make this the primary architecture without a broader
independent requirement to own containerd outside k3s. If issue #183 reproduces
and remains unresolved, test an external-containerd variant beside the bundled
variant. Adopt it only if nix-snapshotter's demonstrated value justifies the
larger runtime ownership boundary and the variant preserves image imports, CNI,
RuntimeClasses, KubeVirt, Woodpecker, and GC behavior.

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

### Option D: Registry-Free DevPod Image Preload And KubeVirt Provider

This option is independent of enabling nix-snapshotter on erebonia. Keep the
inner image as a normal OCI image, preload it into the VM's rootful Podman
store, and let DevPod's standard Docker driver consume the local immutable tag.

Minimal proof using the current wrapper:

- change the devcontainer image to `${localEnv:DEV_MACHINE_IMAGE}` with a
  migration default;
- build `.#dev-machine-dev-image` during `dev-machine up`;
- after SSH is ready, stream or generate it inside the VM and run
  `podman-rootful load`;
- derive a stable local tag from the Nix output identity and fail before
  `devpod up` if `podman-rootful image exists` does not find it;
- forward `DEV_MACHINE_IMAGE` to the remote DevPod agent.

Longer-term consolidation:

- create a reusable custom DevPod KubeVirt machine provider;
- move VM create/delete/status/command, slot assignment, readiness waits, and
  image preload out of the wrapper into provider operations;
- retain DevPod's Docker driver inside the VM, configured with the existing
  `podman-rootful` path;
- keep OIDC/kubectl/virtctl and cluster credentials on the operator side;
- keep post-create Forgejo/Woodpecker credential injection scoped to the
  workspace;
- disable provider-driven inactivity stop while workspace state lives on
  `emptyDisk`.

Pros:

- Removes the mutable `dev-machine-dev:latest` dependency and makes the exact
  Nix-built image part of workspace provisioning.
- Removes the registry and its credentials from the normal inner-image path.
- Gives VM lifecycle, readiness, image realization, and DevPod connection one
  owner.
- Preserves standard DevPod/devcontainer and Podman behavior.

Cons:

- Podman still materializes a second OCI-layer representation beside the Nix
  store.
- Every new ephemeral VM must load the image into scratch-backed Podman storage.
- A full custom provider is a meaningful refactor and must preserve slot,
  rescue, credential, and SSH-host-key behavior.
- Generic DevPod stop/start expectations do not match an `emptyDisk`-backed
  workspace without explicit loss semantics.

Recommendation: **prove preload in the current wrapper first, then implement
the custom KubeVirt machine provider if the lifecycle consolidation remains
valuable.** Do not build a custom DevPod driver merely to accept raw Nix store
paths.

## Recommended Pilot

Pilot scope: one trivial pod image, one KubeVirt containerDisk proof, then one
low-risk Woodpecker build-step image.

Candidate: a new `dotfiles-ci-nix` variant, not the current production tag at
first.

Implementation sketch:

1. Add `nix-snapshotter` as a flake input following this repo's `nixpkgs`.
2. Import only the needed overlay/module on erebonia.
3. Add an opt-in `hosts/erebonia/k3s/nix-snapshotter.nix` module.
4. First add a NixOS VM regression test for upstream issue #183 using
   `pkgs.k3s_1_36`, including a file-valued store path. Do not proceed on
   production erebonia while it fails.
5. Configure k3s's bundled integration without changing the existing runtime
   classes.
6. Build a minimal `pkgs.nix-snapshotter.buildImage` test image with
   `resolvedByNix = true`, such as a `hello` or tiny CI smoke image.
7. Apply a one-shot test Pod through `services.k3s.manifests` or a VM test,
   using a `nix:0/nix/store/...` image reference.
8. Build a scratch-style KubeVirt containerDisk test image with
   `pkgs.nix-snapshotter.buildImage`, placing a small qcow2 under `/disk` with
   UID/GID readable for KubeVirt's qemu user.
9. Apply a one-shot test VMI/VM whose `containerDisk.image` is the resulting
   `nix:0/nix/store/...` reference.
10. Validate:
   - pod starts under ordinary runc;
   - pod starts under `runsc` if build pods keep using gVisor;
   - the KubeVirt test VM reaches Running;
   - the KubeVirt test VM can read/boot the qcow2;
   - normal registry images still pull;
   - existing Woodpecker agent and KubeVirt workloads still start;
   - containerd image GC and Nix GC do not remove running image closures;
   - rollback restores the previous k3s runtime behavior.
11. Only after that, move a non-critical Woodpecker pipeline lane to the
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

1. **k3s 1.36 regression.** The repo's evaluated `1.36.2+k3s1` contains the
   bundled integration, so feature presence is confirmed. The open question is
   correctness: upstream issue #183 must be fixed, avoided with a justified
   constraint, or disproved by a local test before production use. Also cover
   checkpoint-image lookup issue #179. Avoid an external-containerd migration
   unless the embedded path remains unusable after upstream fixes.

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
  additional embedded containerd/image-service code with privileged access to
  the host Nix store. Option B would add separately managed privileged services
  as well, but the recommended bundled integration does not.
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

Potentially, but only as a **targeted supplement**, and not on production with
the currently evaluated k3s version until upstream issue #183 is fixed,
convincingly constrained, or disproved by the local regression test.

It is worthwhile for this repo if the goal is to reduce duplication and
publication/import friction for Nix-native Kubernetes workloads. The k3s path
now has enough upstream evidence to make a pilot reasonable. The largest
possible local win is the dev-machine base VM `containerDisk` path, but that
specific use remains unproven publicly and should be tested before changing the
wrapper's normal behavior. It is not worthwhile as a broad replacement for the
current k8s image-management design because much of the repo's image surface is
third-party OCI, and because the dev-machine devcontainer uses Podman rather
than erebonia's containerd. That Podman path can still be made registry-free by
local preload; it is a parallel improvement, not a nix-snapshotter use case.

The practical recommendation is:

1. Keep the current Forgejo registry and `services.k3s.images` paths as the
   stable baseline.
2. Add an isolated NixOS VM test using the repo's exact k3s 1.36 package and the
   issue #183 file-valued-store-path reproducer. Do not enable it on erebonia
   while that fails.
3. Once the regression is fixed, add nix-snapshotter behind a focused
   erebonia/k3s module only after current CI/KubeVirt behavior is green.
4. Pilot one runc/gVisor pod image.
5. Immediately pilot one KubeVirt containerDisk image.
6. If the containerDisk proof passes, prototype a `publish-base` replacement
   that distributes the Nix closure through Attic or `nix copy` and renders a
   `nix:0/nix/store/...` `containerDisk.image`.
7. Expand to `dotfiles-ci-nix` if the pod/runtime pilot passes.
8. Re-evaluate `ci-worker-base` only after ordinary pod images and a small
   containerDisk are proven.
9. In parallel, prove registry-free inner-image preload using the existing
   wrapper: load the Nix-built OCI stream into rootful Podman under an immutable
   content-derived tag and select it with `DEV_MACHINE_IMAGE` substitution.
10. If that proof is reliable, replace the dynamically generated per-machine
    SSH providers with a reusable custom DevPod KubeVirt machine provider that
    owns VM lifecycle, readiness, and image preload while retaining the normal
    in-VM Docker/Podman driver.
11. Do not enable provider-driven inactivity stop while the workspace and
    Podman state live on KubeVirt `emptyDisk`, and do not switch the workspace
    to DevPod's Kubernetes driver.

If the pilot requires external-containerd migration or k3s patching beyond a
small, maintainable module, defer adoption. If the pod pilot succeeds but the
containerDisk pilot fails, still consider nix-snapshotter for CI pod images, but
leave `dev-machine publish-base` on the Forgejo registry path.
