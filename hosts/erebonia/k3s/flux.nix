{
  config,
  pkgs,
  lib,
  ...
}: {
  # ── Chunk 2c — Flux (GitOps controllers) ────────────────────────────────────
  # Flux owns the cluster's *dynamic* layer: net-new workloads land as
  # Flux-watched manifests (see k3s-cluster-workloads-plan.md), not as NixOS
  # modules. This flake provides the *platform* (runtimes, cert-manager, Kyverno,
  # Flux itself); Flux reconciles everything above it.
  #
  # At bootstrap we install the **controllers only**. The GitRepository +
  # Kustomization that point Flux at the dynamic-manifest path are still NOT
  # created here — but open decision #4 (monorepo path vs. separate repo) is now
  # **resolved to the monorepo**: Flux's source is *this* repo (dotfiles on
  # creil), manifests under a watched path here, hand-written YAML for now and
  # Nix-generated once CI can render-and-commit them. See
  # `llm-notes/plans/incus-workstation-migration-plan.md` ("Decision #4 …
  # resolved: monorepo"). What remains is the concrete wiring (GitRepository +
  # Kustomization + a read-only creil deploy key), tracked by the workloads plan.
  #
  # Community flux2 chart (CNCF Flux upstream), pinned. Image-automation and
  # image-reflector controllers are disabled — they watch container registries
  # for tag updates, which nothing here uses yet; drop them to stay lean on the
  # single node. helm/kustomize/source/notification controllers are kept.
  services.k3s.autoDeployCharts.flux2 = {
    repo = "https://fluxcd-community.github.io/helm-charts";
    name = "flux2";
    version = "2.18.4";
    hash = "sha256-Ji8GRuYP/bUP+clE3QpkVcp+ZDWbI3/4ou3WC1kW9Xo=";
    targetNamespace = "flux-system";
    createNamespace = true;
    values = {
      imageAutomationController.create = false;
      imageReflectorController.create = false;
    };
  };
}
