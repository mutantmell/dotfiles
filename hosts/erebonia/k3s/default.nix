{
  config,
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost "erebonia") host zone;

  # Datastore lives on a dedicated btrfs subvolume under /persist — the
  # impermanence-persistent subvolume that is NOT rolled back on boot (see
  # profiles/disko/btrfs.nix: @root is reset, @persist survives). Being its own
  # subvolume (not just a directory) is what makes it independently
  # snapshottable. This is the resolution of open decision #2 in
  # llm-notes/wip/k3s-cluster-bootstrap-plan.md: persisted btrfs subvolume +
  # local btrfs snapshots; off-host backup to liberl deferred to the CI/CD plan.
  dataDir = "/persist/k3s";
  snapshotDir = "/persist/.k3s-snapshots";
  snapshotKeep = 14;
in {
  # ── Datastore subvolume ────────────────────────────────────────────────────
  # `v` creates a btrfs subvolume (falls back to a plain dir on non-btrfs). Runs
  # at systemd-tmpfiles-setup, ordered before k3s.service, so the subvolume
  # exists on first boot before k3s writes to it.
  systemd.tmpfiles.rules = [
    "v ${dataDir} 0700 root root - -"
    "d ${snapshotDir} 0700 root root - -"
  ];

  # ── k3s control plane (all-in-one server) ──────────────────────────────────
  # role = "server" with the agent included (no --disable-agent): this single
  # node is both control plane and worker. Bundled sqlite (kine) datastore; no
  # clusterInit (that flips to embedded etcd / HA — deferred, see the plan's
  # "Deferred — multi-node & HA").
  services.k3s = {
    enable = true;
    role = "server";
    package = pkgs.k3s_1_33; # pinned minor; bump deliberately (nixpkgs default is 1_35)
    extraFlags = [
      "--data-dir=${dataDir}"
      # apiserver cert SANs so `kubectl` works by hostname/IP from a lab/trusted
      # VLAN workstation, not only via localhost. 127.0.0.1/localhost are SANs
      # by default.
      "--tls-san=erebonia"
      "--tls-san=erebonia.internal"
      "--tls-san=${host.ipv4}"
      "--tls-san=${host.ipv6}"
      # group-readable kubeconfig at /etc/rancher/k3s/k3s.yaml for the operator
      # to copy out (rewrite server: https://erebonia.internal:6443 on the
      # workstation copy).
      "--write-kubeconfig-mode=0640"
    ];
  };

  # ── Datastore snapshots (decision #2) ──────────────────────────────────────
  # Read-only btrfs snapshot of the whole data-dir subvolume (captures the kine
  # SQLite db + WAL crash-consistently — acceptable for SQLite/WAL). Daily, keep
  # the most recent `snapshotKeep`. This is the cluster's primary control-plane
  # recovery mechanism until the deferred off-host copy to liberl lands.
  systemd.services.k3s-datastore-snapshot = {
    description = "Snapshot the k3s datastore subvolume (btrfs)";
    # Don't race a snapshot against an in-progress shutdown/restart of k3s.
    after = ["k3s.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "k3s-datastore-snapshot" ''
        set -euo pipefail
        ts=$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)
        ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r ${dataDir} ${snapshotDir}/k3s-"$ts"
        # Prune all but the newest ${toString snapshotKeep} read-only snapshots.
        ${pkgs.coreutils}/bin/ls -1d ${snapshotDir}/k3s-* 2>/dev/null \
          | ${pkgs.coreutils}/bin/sort \
          | ${pkgs.coreutils}/bin/head -n -${toString snapshotKeep} \
          | while read -r old; do
              ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$old"
            done
      '';
    };
  };
  systemd.timers.k3s-datastore-snapshot = {
    description = "Daily k3s datastore snapshot";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  # ── Host firewall ──────────────────────────────────────────────────────────
  # erebonia uses the nftables firewall backend (incus enables it). The CNI
  # interfaces must be trusted so pod→host traffic (pods reaching the apiserver
  # ClusterIP, cluster DNS, etc.) bypasses the default-drop input policy.
  # `extraInputRules` is a `lines` option and merges (concatenates) with the
  # SSH-tightening rules already defined in hosts/erebonia/microvm/default.nix.
  networking.firewall = {
    trustedInterfaces = ["cni0" "flannel.1"];
    extraInputRules = ''
      ip saddr { ${zone.subnet4}, ${net.networks.lab.subnet4}, ${net.networks.trusted.subnet4} } tcp dport 6443 accept
      ip6 saddr { ${zone.subnet6}, ${net.networks.lab.subnet6}, ${net.networks.trusted.subnet6} } tcp dport 6443 accept
    '';
  };

  # `kubectl`/`crictl` on the host point at the bundled kubeconfig by default.
  environment.systemPackages = [pkgs.kubectl];
  environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
}
