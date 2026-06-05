{
  config,
  pkgs,
  lib,
  ...
}: let
  # Chunk 1b — runtime-tier baseline. k3s 1.33 auto-creates RuntimeClasses only
  # for its built-in list (crun, nvidia, the wasm family, lunatic); runsc and
  # kata are NOT in it. So we register the containerd handlers and the
  # RuntimeClass objects explicitly.
  #
  # containerd is v3 here (k3s 1.33 bundles containerd 2.0). The generated
  # config imports `config-v3.toml.d/*.toml`, so we add handlers as a drop-in
  # rather than templating the whole base. Plugin path is
  # `io.containerd.cri.v1.runtime` (v3), mirroring the live `runc` stanza.
  dataDir = "/persist/k3s";
  containerdDir = "${dataDir}/agent/etc/containerd";
  dropinDir = "${containerdDir}/config-v3.toml.d";

  kataQemuConfig = "${pkgs.kata-runtime}/share/defaults/kata-containers/configuration-qemu.toml";

  # gVisor (runsc): shim `containerd-shim-runsc-v1`, type `io.containerd.runsc.v1`.
  # kata-qemu: shim `containerd-shim-kata-qemu-v2`, type `io.containerd.kata-qemu.v2`,
  #   ConfigPath → the qemu toml nixpkgs already patched (kata-images kernel/rootfs,
  #   virtiofsd, QEMUPATH baked in). No /etc/kata-containers needed.
  # runc-kvm: a second runc handler for the lighter nested-virt path. NOTE: this
  #   only registers the handler/class; pods get /dev/kvm via a kvm device plugin
  #   added with the AI-coding-layer workload (Phase A), not here. kata-qemu is
  #   the self-contained /dev/kvm path the Phase-1 validation exercises.
  extraRuntimes = pkgs.writeText "k3s-extra-runtimes.toml" ''
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
      runtime_type = "io.containerd.runsc.v1"

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-qemu]
      runtime_type = "io.containerd.kata-qemu.v2"

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-qemu.options]
      ConfigPath = "${kataQemuConfig}"

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
  # Make the runtime shims/binaries discoverable to k3s' embedded containerd
  # (it execs `containerd-shim-<rt>-v*` from the k3s.service PATH).
  systemd.services.k3s.path = [pkgs.gvisor pkgs.kata-runtime];

  # Drop the extra-runtimes handlers into the imported `config-v3.toml.d`. Runs
  # at tmpfiles-setup, before k3s.service, so containerd sees them on first start.
  systemd.tmpfiles.rules = [
    "d ${dropinDir} 0755 root root - -"
    "L+ ${dropinDir}/10-extra-runtimes.toml - - - - ${extraRuntimes}"
  ];

  # RuntimeClass objects (auto-applied from the k3s server manifests dir).
  services.k3s.manifests.runtimeclasses.content = [
    (mkRuntimeClass "runsc")
    (mkRuntimeClass "kata-qemu")
    (mkRuntimeClass "runc-kvm")
  ];
}
