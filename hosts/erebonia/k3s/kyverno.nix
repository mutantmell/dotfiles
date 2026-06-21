{
  config,
  pkgs,
  lib,
  ...
}: let
  # ── Chunk 2b — Kyverno admission policies for the CI builds namespace ────────
  # Kyverno is the admission engine. At bootstrap it carries only the two
  # ClusterPolicies that the report's Appendix-A CI stack relies on, and they are
  # **scoped to the untrusted-code namespace only** (`woodpecker-builds`). This
  # is load-bearing: the report warns that applying image-source / runtimeClass
  # enforcement cluster-wide would deadlock the bootstrap (kube-system,
  # flux-system, cert-manager, kyverno itself would all be rejected). Because the
  # policies match Pods *only* in `woodpecker-builds`, they are inert until that
  # namespace + the Woodpecker workload land in the workloads/CI plan — they
  # never fire on platform namespaces.
  #
  # The `woodpecker-builds` namespace itself, its PSS `restricted` labels, the
  # NetworkPolicy, and the Woodpecker server/runners are NOT created here — they
  # belong to the CI workload (k3s-cluster-workloads-plan.md Phase 4 / report
  # Appendix A). Bootstrap only installs the engine + the scoped policies.
  buildsNamespace = "woodpecker-builds";

  # Exact image references allowed in CI build pods. These are preloaded through
  # services.k3s.images in woodpecker-ci.nix, so this is an allowlist of the
  # node-local CI platform images, not a broad registry trust policy.
  allowedBuildImages = [
    "docker.io/woodpeckerci/woodpecker-agent:v3.15.0"
    "docker.io/woodpeckerci/plugin-git:2.9.1"
    "busybox:stable-musl"
    "localhost/dotfiles-ci-nix:0.1.0"
  ];

  mkBuildsMatch = {
    any = [
      {
        resources = {
          kinds = ["Pod"];
          namespaces = [buildsNamespace];
        };
      }
    ];
  };
in {
  # Kyverno Helm chart, pinned. Lean single-node install: keep only the
  # admission controller (the webhook that enforces validate policies). The
  # background, reports, and cleanup controllers are for policy-report
  # generation, mutate-existing, and CleanupPolicy — none of which the
  # admission-time Enforce policies below need — so they are disabled to save
  # memory on erebonia.
  services.k3s.autoDeployCharts.kyverno = {
    repo = "https://kyverno.github.io/kyverno";
    name = "kyverno";
    version = "3.8.1";
    hash = "sha256-oz81uDtpkdr2obHPmVvsvjaXR/zYRBHVCJ1VpA7krg0=";
    targetNamespace = "kyverno";
    createNamespace = true;
    values = {
      admissionController.replicas = 1;
      backgroundController.enabled = false;
      reportsController.enabled = false;
      cleanupController.enabled = false;
    };
  };

  # ClusterPolicies scoped to woodpecker-builds. `background: false` since the
  # background controller is disabled; enforcement is at admission only. Uses
  # rule-level `validate.failureAction` (Kyverno 1.12+; the spec-level
  # `validationFailureAction` is deprecated).
  services.k3s.manifests.kyverno-builds-policies.content = [
    {
      apiVersion = "kyverno.io/v1";
      kind = "ClusterPolicy";
      metadata.name = "require-runsc-in-builds";
      spec = {
        background = false;
        rules = [
          {
            name = "require-runsc";
            match = mkBuildsMatch;
            validate = {
              failureAction = "Enforce";
              message = "Pods in ${buildsNamespace} must set runtimeClassName: runsc (gVisor sandbox).";
              pattern.spec.runtimeClassName = "runsc";
            };
          }
        ];
      };
    }
    {
      apiVersion = "kyverno.io/v1";
      kind = "ClusterPolicy";
      metadata.name = "restrict-image-registry-in-builds";
      spec = {
        background = false;
        rules = [
          {
            name = "validate-registry";
            match = mkBuildsMatch;
            validate = {
              failureAction = "Enforce";
              message = "Images in ${buildsNamespace} must be one of the approved preloaded Woodpecker CI images.";
              foreach = [
                {
                  list = "request.object.spec.[ephemeralContainers, initContainers, containers][]";
                  deny.conditions.all = [
                    {
                      key = "{{ element.image }}";
                      operator = "NotIn";
                      value = allowedBuildImages;
                    }
                  ];
                }
              ];
            };
          }
        ];
      };
    }
  ];
}
