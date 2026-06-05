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
  # Kustomization that point Flux at the dynamic-manifest path are deliberately
  # NOT created here: open decision #4 (monorepo path vs. separate repo, and the
  # repo URL/auth) is unresolved and explicitly deferred to the workloads plan.
  # Wiring a concrete source now would prematurely decide #4. Bootstrap milestone
  # is the controllers Running/healthy; the source lands with decision #4.
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
