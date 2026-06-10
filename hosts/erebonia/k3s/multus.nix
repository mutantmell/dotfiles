{
  config,
  pkgs,
  lib,
  ...
}: let
  # The namespace the KubeVirt dev-machine VMs (and their NADs) live in. Must match
  # `programs.dev-machine.namespace` on the operator's workstation (home/modules/
  # dev-machine.nix, default "dev-machines"); the launcher creates it on demand,
  # but declaring it here makes it exist at apply time so the NADs below can land.
  devNamespace = "dev-machines";

  # ── VLAN-51 attach = macvtap (NOT a host bridge) ──────────────────────────────
  # The dev VMs attach to VLAN 51 through KubeVirt's macvtap binding on a macvtap
  # child of `uplink.51` — deliberately NOT the host Linux bridge `br51`. While
  # k3s forces `net.bridge.bridge-nf-call-iptables=1` (cni0 + NetworkPolicy need
  # it), `br_netfilter` drags any host-bridge's bridged VLAN-51 frames through the
  # host L3/conntrack pipeline, which silently drops cross-subnet / routed-in
  # traffic (the real `lab → dev-N` path) to a host-IP-less bridge guest — no nft
  # rule, inside br_netfilter itself. Proven by elimination (link route, rp_filter,
  # bridge IP, notrack all fail; only `bridge-nf-call-iptables=0` or not-a-bridge
  # works). macvtap is not a Linux bridge, so it never enters br_netfilter; it also
  # matches the macvtap pattern erebonia already uses for VLAN 50/100 guests, and
  # gives host↔guest isolation. See
  # llm-notes/wip/dev-machine-vlan51-macvtap-cutover.md.
  #
  # IP delivery moved with it. macvtap does NO in-pod DHCP (that was a bridge-
  # binding feature that leased the NAD static-IPAM IP to the DHCP-only guest), so
  # the guest DHCPs its slot IP from the real VLAN-51 DHCP on bt8gw, keyed on the
  # launcher-pinned per-slot MAC. The MAC's last byte IS the IP host octet (mac_for_slot:
  # dev-N → hostid 9+N → MAC 02:51:51:00:00:<hex(9+N)>), so dev-1 = 02:51:51:00:00:0a →
  # .10 … dev-16 = 02:51:51:00:00:19 → .25 (bt8gw reservations). Slot identity is now
  # MAC + DHCP reservation, NOT the NAD — so the 16 per-slot static-IPAM NADs collapse
  # to the ONE macvtap NAD below.

  # ── macvtap-cni: CNI plugin + device plugin ───────────────────────────────────
  # Advertises `capacity` allocatable macvtap devices on `uplink.51` as the k8s
  # extended resource `macvtap.network.kubevirt.io/<name>` (name = the config's
  # `name`, NOT the lowerDevice — so a clean dot-free `cluster-vlan51`). The NAD's
  # resourceName annotation requests it; KubeVirt's resource injection wires it
  # onto the VMI pod. Pinned upstream image; the only k3s adaptation vs upstream is
  # the CNI install dir → k3s' writable `/var/lib/rancher/k3s/data/cni` (the same
  # binDir the multus chart points delegates at), not `/opt/cni/bin`.
  macvtapImage = "quay.io/kubevirt/macvtap-cni:v0.13.1";
  macvtapResource = "cluster-vlan51";
  macvtapLowerDevice = "uplink.51";
  macvtapCapacity = 16;

  macvtapConfigMap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "macvtap-deviceplugin-config";
      namespace = "kube-system";
    };
    data.DP_MACVTAP_CONF = builtins.toJSON [
      {
        name = macvtapResource;
        lowerDevice = macvtapLowerDevice;
        mode = "bridge";
        capacity = macvtapCapacity;
      }
    ];
  };

  macvtapDaemonSet = {
    apiVersion = "apps/v1";
    kind = "DaemonSet";
    metadata = {
      name = "macvtap-cni";
      namespace = "kube-system";
    };
    spec = {
      selector.matchLabels.name = "macvtap-cni";
      template = {
        metadata.labels.name = "macvtap-cni";
        spec = {
          hostNetwork = true;
          hostPID = true;
          priorityClassName = "system-node-critical";
          containers = [
            {
              name = "macvtap-cni";
              command = ["/macvtap-deviceplugin" "-v" "3" "-logtostderr"];
              envFrom = [{configMapRef.name = "macvtap-deviceplugin-config";}];
              image = macvtapImage;
              imagePullPolicy = "IfNotPresent";
              resources.requests = {
                cpu = "60m";
                memory = "30Mi";
              };
              securityContext.privileged = true;
              volumeMounts = [
                {
                  name = "deviceplugin";
                  mountPath = "/var/lib/kubelet/device-plugins";
                }
              ];
              terminationMessagePolicy = "FallbackToLogsOnError";
              readinessProbe = {
                exec.command = ["sh" "-c" "ls /var/lib/kubelet/device-plugins/macvtap.network.kubevirt.io* >/dev/null 2>&1"];
                initialDelaySeconds = 5;
                periodSeconds = 10;
              };
              livenessProbe = {
                exec.command = ["sh" "-c" "ls /var/lib/kubelet/device-plugins/macvtap.network.kubevirt.io* >/dev/null 2>&1"];
                initialDelaySeconds = 15;
                periodSeconds = 60;
              };
            }
          ];
          initContainers = [
            {
              name = "install-cni";
              command = ["cp" "/macvtap-cni" "/host/opt/cni/bin/macvtap"];
              image = macvtapImage;
              imagePullPolicy = "IfNotPresent";
              resources.requests = {
                cpu = "10m";
                memory = "15Mi";
              };
              securityContext.privileged = true;
              volumeMounts = [
                {
                  name = "cni";
                  mountPath = "/host/opt/cni/bin";
                  mountPropagation = "Bidirectional";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "deviceplugin";
              hostPath.path = "/var/lib/kubelet/device-plugins";
            }
            {
              # k3s' writable CNI bin dir (NOT /opt/cni/bin) — same dir the multus
              # chart points delegates at (cni_conf.binDir above).
              name = "cni";
              hostPath.path = "/var/lib/rancher/k3s/data/cni";
            }
          ];
        };
      };
    };
  };

  # Single macvtap NAD for VLAN 51 (was 16 per-slot bridge NADs). The launcher
  # pins the per-slot MAC on the VMI; the IP comes from bt8gw DHCP — so one NAD
  # serves every slot. No IPAM (macvtap is L2-only; the guest DHCPs).
  clusterVlan51Nad = {
    apiVersion = "k8s.cni.cncf.io/v1";
    kind = "NetworkAttachmentDefinition";
    metadata = {
      name = "cluster-vlan51";
      namespace = devNamespace;
      annotations."k8s.v1.cni.cncf.io/resourceName" = "macvtap.network.kubevirt.io/${macvtapResource}";
    };
    spec.config = builtins.toJSON {
      cniVersion = "0.3.1";
      name = "cluster-vlan51";
      type = "macvtap";
      mtu = 1500;
    };
  };
in {
  # ── Phase D.1/D.2 — Multus + the reference CNI plugins (bring-up checklist) ───
  # cluster-vlan-bringup-checklist.md Phase D, the [cluster] half. Multus is the
  # CNI *multiplexer* that lets the locked-down dev-machine VM attach a SECOND
  # interface straight onto VLAN 51 (a macvtap child of uplink.51 — see the
  # macvtap section above) and skip the flannel pod network entirely — so it is a
  # routable host in the low-trust
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

  # ── Phase D.3 — the per-slot VLAN-51 NADs + their namespace ───────────────────
  # The dev VM references one of these NADs (D.4) to get its `br51` interface with
  # its slot's pinned IP. Authored as `.content` so k3s' deploy controller
  # re-applies them until Multus has installed the `NetworkAttachmentDefinition`
  # CRD they depend on, then they stick — the same admission-ordering trick
  # kubevirt-cr / the step-ca ClusterIssuer use.
  services.k3s.manifests.dev-machines-namespace.content = [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = devNamespace;
    }
  ];

  # macvtap-cni (CNI + device plugin) exposing uplink.51 as the macvtap resource.
  services.k3s.manifests.macvtap-cni.content = [
    macvtapConfigMap
    macvtapDaemonSet
  ];

  # The single VLAN-51 macvtap NAD the dev VMs attach to (see clusterVlan51Nad).
  services.k3s.manifests.cluster-vlan51-nad.content = [clusterVlan51Nad];
}
