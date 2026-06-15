{
  config,
  pkgs,
  lib,
  ...
}: let
  # ── Phase 1 — KubeVirt platform (ai-dev-machine-kubevirt-plan.md) ────────────
  # KubeVirt is the VM substrate for the locked-down LLM dev machines: a
  # `VirtualMachine` is the security boundary, and because erebonia's host runs
  # `kvm_intel nested=1` (hosts/erebonia/default.nix), the regular NixOS kernel
  # inside that VM gets /dev/kvm natively — the flake's `nixosTest` suite runs
  # nested with no custom guest kernel.
  #
  # Install method: the **upstream operator release manifest**, pinned + FOD-
  # fetched, applied straight from the k3s server manifests dir — NOT a Helm
  # chart. KubeVirt ships no official Helm chart (the community ones are flagged
  # "not production ready" and only re-wrap this same YAML), so the canonical
  # operator manifest is both the maintained path and the closest fit to the
  # `services.k3s.manifests.<name>` auto-apply pattern the rest of the platform
  # uses (cert-manager.nix / kyverno.nix / flux.nix land HelmCharts the same way,
  # but here `.source`/`.content` carry plain manifests instead).
  #
  # Bump deliberately: refresh both `kubevirtVersion` and the operator manifest
  # hash together (the hash pins one release's YAML), then re-deploy.
  kubevirtVersion = "v1.8.3";

  # The operator Deployment + its RBAC + the single `kubevirts.kubevirt.io` CRD,
  # and the `kubevirt` namespace. (The `VirtualMachine`/`VirtualMachineInstance`
  # CRDs Phase 3 uses are NOT in this file — virt-operator installs them once it
  # reconciles the KubeVirt CR below.) FOD (hash-pinned) so the build is
  # reproducible and needs no in-cluster fetch; k3s' deploy controller symlinks
  # it into the manifests dir and `kubectl apply`s it.
  kubevirtOperator = pkgs.fetchurl {
    url = "https://github.com/kubevirt/kubevirt/releases/download/${kubevirtVersion}/kubevirt-operator.yaml";
    hash = "sha256-EoGkxQDbiBjJLabpF0EYFup5WDPyjeYY9IHTzjv+96k=";
  };
in {
  # The operator manifest, applied verbatim. Lands as `kubevirt-operator.yaml`.
  services.k3s.manifests.kubevirt-operator.source = kubevirtOperator;

  # The singleton `KubeVirt` CR the operator reconciles into virt-api,
  # virt-controller, and the virt-handler DaemonSet. Authored as `.content` (not
  # part of the operator file) so the deploy controller re-applies it until the
  # operator has installed the `kubevirt.io/v1` CRD it depends on, then it
  # sticks — same admission-ordering trick as cert-manager's ClusterIssuer.
  #
  # Single-node homelab tuning, mirroring the platform charts' "one replica is
  # plenty" posture:
  #   - infra.replicas = 1 — virt-api/virt-controller default to 2 each, wasted
  #     on a single node. virt-handler is a per-node DaemonSet regardless.
  #   - useEmulation stays false (default): boot VMs on real KVM, never fall back
  #     to slow software emulation. The whole point is hardware (nested) virt.
  # No feature gates are needed for the dev-machine path: nested KVM is a
  # host-kernel + per-VMI CPU-model concern (Phase 1.3 base image / Phase 3 VMI
  # spec), not a KubeVirt operator toggle.
  services.k3s.manifests.kubevirt-cr.content = [
    {
      apiVersion = "kubevirt.io/v1";
      kind = "KubeVirt";
      metadata = {
        name = "kubevirt";
        namespace = "kubevirt";
      };
      spec = {
        certificateRotateStrategy = {};
        configuration = {
          developerConfiguration = {
            useEmulation = false;
          };
          # macvtap network binding plugin. The dev VMs attach to VLAN 51 via
          # macvtap on uplink.51 (k3s/multus.nix), NOT the host br51 bridge, so
          # their frames bypass br_netfilter's L3 pipeline — which silently drops
          # cross-subnet/routed-in traffic (e.g. lab → dev-N) to a host-IP-less
          # bridge guest while k3s forces bridge-nf-call-iptables=1 (proven dead
          # end; see llm-notes/done/dev-machine-vlan51-macvtap-cutover.md). No
          # feature gate: network binding plugins are default-on since v1.5.
          network.binding.macvtap.domainAttachmentType = "tap";
        };
        customizeComponents = {};
        imagePullPolicy = "IfNotPresent";
        infra.replicas = 1;
      };
    }
  ];
}
