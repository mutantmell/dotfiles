{
  config,
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  cluster = net.networks.cluster;

  # The namespace the KubeVirt dev-machine VMs (and their NAD) live in. Must match
  # `programs.dev-machine.namespace` on the operator's workstation (home/modules/
  # dev-machine.nix, default "dev-machines"); the launcher creates it on demand,
  # but declaring it here makes it exist at apply time so the NAD below can land.
  devNamespace = "dev-machines";
in {
  # ── Phase D.1/D.2 — Multus + the reference CNI plugins (bring-up checklist) ───
  # cluster-vlan-bringup-checklist.md Phase D, the [cluster] half. Multus is the
  # CNI *multiplexer* that lets the locked-down dev-machine VM attach a SECOND
  # interface straight onto VLAN 51 (the host-IP-less `br51` bridge, B.3) and skip
  # the flannel pod network entirely — so it is a routable host in the low-trust
  # `cluster` zone, confined by bt8gw fw4 (Phase C, confirmed enforcing), with no
  # adjacency to erebonia's VLAN-11 management plane. Multus is ADDITIVE: flannel
  # stays the primary CNI for every normal pod; only the dev VM goes multus-only
  # (D.4, deferred to the launcher-rework slice).
  #
  # Install method: the **rke2-multus Helm chart** (Rancher's), which is the path
  # the official k3s docs prescribe for Multus on k3s
  # (https://docs.k3s.io/networking/multus-ipams). It is purpose-built for k3s'
  # non-standard CNI layout: its DaemonSet writes the multus binary AND the
  # reference CNI plugins (bridge, static, host-local, macvlan, loopback, …) into
  # k3s' WRITABLE bin dir `/var/lib/rancher/k3s/data/cni/` and drops the multus
  # conf into `/var/lib/rancher/k3s/agent/etc/cni/net.d`. That sidesteps the
  # immutable `data/<hash>/bin` problem a hand-rolled daemonset hits on k3s, and
  # it satisfies checklist D.2 (the `bridge` + `static` delegates the NAD needs)
  # without a separate `cni-plugins` drop. (k3s ≥ Oct-2024 / 1.36 here reads that
  # writable dir.)
  #
  # autoDeployCharts FOD-fetches the chart tgz at build time (hash-pinned) and
  # hands it to k3s' helm-controller via the local static-charts path — no
  # in-cluster internet fetch, same posture as cert-manager.nix / flux.nix. Bump
  # `version` + `hash` together (re-pin with `nix build` — it prints the new hash
  # on mismatch). The chart's DaemonSet still pulls its container images
  # (rancher/hardened-multus-cni, hardened-cni-plugins) from docker.io, which
  # erebonia can reach on the management plane.
  #
  # RUNTIME VERIFICATION (this is [cluster] + not run-checks-testable, like the
  # bt8gw work): after apply, confirm the multus DaemonSet is Running, that
  # `ls /var/lib/rancher/k3s/data/cni/` shows `bridge` + `static`, and that
  # existing flannel pods are UNAFFECTED (regression, checklist F.3) before
  # cutting any VM over in D.4.
  services.k3s.autoDeployCharts.multus = {
    repo = "https://rke2-charts.rancher.io";
    name = "rke2-multus";
    version = "4.2.411";
    hash = "sha256-+Z98LpMLl4IHAuzkv1VBhWPC+raxtC9UlOiJTYHZEgI=";
    targetNamespace = "kube-system";
    values = {
      config = {
        fullnameOverride = "multus";
        # Point Multus at k3s' CNI dirs (NOT the upstream /opt/cni/bin defaults).
        cni_conf = {
          confDir = "/var/lib/rancher/k3s/agent/etc/cni/net.d";
          binDir = "/var/lib/rancher/k3s/data/cni/";
          kubeconfig = "/var/lib/rancher/k3s/agent/etc/cni/net.d/multus.d/multus.kubeconfig";
          multusAutoconfigDir = "/var/lib/rancher/k3s/agent/etc/cni/net.d";
        };
      };
    };
  };

  # ── Phase D.3 — the VLAN-51 NetworkAttachmentDefinition + its namespace ───────
  # The dev VM references this NAD (D.4) to get its `br51` interface. Authored as
  # `.content` so k3s' deploy controller re-applies it until Multus has installed
  # the `NetworkAttachmentDefinition` CRD it depends on, then it sticks — the same
  # admission-ordering trick kubevirt-cr / the step-ca ClusterIssuer use.
  services.k3s.manifests.dev-machines-namespace.content = [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = devNamespace;
    }
  ];

  services.k3s.manifests.cluster-vlan51-nad.content = [
    {
      apiVersion = "k8s.cni.cncf.io/v1";
      kind = "NetworkAttachmentDefinition";
      metadata = {
        name = "cluster-vlan51";
        namespace = devNamespace;
      };
      # spec.config is a CNI conflist JSON STRING. bridge delegate enslaving the
      # VM veth into the pre-existing host-IP-less `br51` (B.3) — which already
      # carries tag 51 via the enslaved `uplink.51`, so the CNI adds the veth
      # untagged and the L2 tagging happens on the uplink (cf. the microvm
      # default.nix br51 comment). No host IP on br51 (isGateway/ipMasq false) →
      # bt8gw `10.97.51.1` is the only gateway; routing + egress policy live there.
      #
      # IPAM = static with NO baked address: the *slot* model (A.1) means the
      # launcher (D.4) picks a free dev-N and injects that slot's IP per-VM via the
      # `k8s.v1.cni.cncf.io/networks` annotation `ips` field — which `capabilities:
      # {ips:true}` enables. The default routes (v4 + v6) are shared by every slot,
      # so they ARE baked here, pointing at the bt8gw gateway derived from the
      # registry `cluster` zone.
      spec.config = builtins.toJSON {
        cniVersion = "1.0.0";
        name = "cluster-vlan51";
        type = "bridge";
        bridge = "br51";
        isGateway = false;
        isDefaultGateway = false;
        ipMasq = false;
        hairpinMode = false;
        capabilities.ips = true;
        ipam = {
          type = "static";
          routes = [
            {
              dst = "0.0.0.0/0";
              gw = cluster.gateway4;
            }
            {
              dst = "::/0";
              gw = cluster.gateway6;
            }
          ];
        };
      };
    }
  ];
}
