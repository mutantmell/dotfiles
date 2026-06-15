{
  config,
  pkgs,
  lib,
  ...
}: let
  # k3s' embedded containerd reads v3 drop-ins from this directory. Keep this
  # module scoped to runtime classes that have current workloads: gVisor for
  # sandboxed build pods and a runc-kvm handler for future KVM device-plugin use.
  dataDir = "/persist/k3s";
  containerdDir = "${dataDir}/agent/etc/containerd";
  dropinDir = "${containerdDir}/config-v3.toml.d";

  extraRuntimes = pkgs.writeText "k3s-extra-runtimes.toml" ''
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
      runtime_type = "io.containerd.runsc.v1"

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc-kvm]
      runtime_type = "io.containerd.runc.v2"

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc-kvm.options]
      SystemdCgroup = true
  '';

  mkRuntimeClass = name: {
    apiVersion = "node.k8s.io/v1";
    kind = "RuntimeClass";
    metadata.name = name;
    handler = name;
  };
in {
  # Make the runsc shim discoverable to k3s' embedded containerd. The runc-kvm
  # handler uses k3s' existing runc path.
  systemd.services.k3s.path = [pkgs.gvisor];

  # containerd only reads the drop-in at startup. Restart k3s when this file
  # changes so the embedded containerd re-reads the registered runtimes.
  systemd.services.k3s.restartTriggers = [extraRuntimes];

  systemd.tmpfiles.rules = [
    "d ${dropinDir} 0755 root root - -"
    "L+ ${dropinDir}/10-extra-runtimes.toml - - - - ${extraRuntimes}"
  ];

  services.k3s.manifests.runtimeclasses.content = [
    (mkRuntimeClass "runsc")
    (mkRuntimeClass "runc-kvm")
  ];
}
