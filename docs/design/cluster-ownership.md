# Cluster ownership and dependency delivery

Status: current bootstrap and agreed target, reviewed against this checkout. Live reconciliation is not established by configuration alone.

NixOS owns hosts, the k3s runtime, and the minimum Flux bootstrap. Flux is the intended owner of Kubernetes add-ons and workloads. Nix owns dependency selection, pinning, rendering, and validation. Commit generated YAML so the desired resources remain reviewable. The source is this monorepo on `mutantmell-net/dotfiles`, with separate paths for each cluster.

Today `hosts/erebonia/k3s/flux.nix` installs controllers through `autoDeployCharts.flux2`. It does not declare a GitRepository, Kustomization, watched path, or source credential. Several platform add-ons are still NixOS-managed. Installing controllers does not mean GitOps delivery is operational.

The target bootstrap is pinned Nix-generated Flux manifests applied by NixOS/k3s. Migrate add-ons one at a time, with exactly one reconciler owning each resource. Transfer ownership without deleting persistent data. Define CRD ordering, dependency/health checks, Helm remediation, suspension, and pruning policy before migration.

Flux and Comin will consume protected `release`; resource health does not order NixOS host activation. See [fleet delivery](fleet-delivery.md) for exact-commit publication, verification, offline rejoin, and recovery requirements. Runtime dependencies must constrain deployed bytes through digests or verified immutable chart artifacts; CI fetch hashes alone do not pin what a cluster downloads.

Use a Nix dependency registry for charts, raw manifests, bootstrap releases, and selected controller images. Keep update PRs narrow and regeneration deterministic. Preserve an operator bootstrap/recovery path outside k3s.

The existing k3s state is local SQLite on a persisted btrfs subvolume with scheduled snapshots (`hosts/erebonia/k3s/default.nix`). This is not an off-host recovery proof. CA/token adoption is seed-if-absent (`ca-adoption.nix`); editing sops inputs does not rotate running identities. Persistent workstation migration and CSI storage remain proposed work.
