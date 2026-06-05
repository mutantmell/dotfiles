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

  # Chunk 1c — kata on Cloud Hypervisor. nixpkgs' kata-runtime builds
  # HYPERVISORS=qemu but still SHIPS configuration-clh.toml, and that toml is
  # fully Nix-pathed: kernel/image → kata-images, virtio_fs_daemon → virtiofsd.
  # The ONLY broken reference is the hypervisor binary — the toml expects
  # `${out}/bin/cloud-hypervisor`, which the package never installs. Symlinking
  # nixpkgs' cloud-hypervisor into $out/bin makes the shipped toml resolve as-is:
  # the toml's `path`/`valid_hypervisor_paths` are self-referential to this
  # derivation's own $out, so the override's new out is exactly what they point
  # at (verified by build — the symlink lands where the toml looks). No
  # HYPERVISORS= rebuild, no toml editing. The `containerd-shim-kata-clh-v2`
  # symlink already ships in kata-runtime (already on the k3s PATH below), and
  # the kata shim binary is unchanged by the override, so the qemu/clh shims are
  # interchangeable; only the ConfigPath below selects the hypervisor. See
  # project_nixpkgs_kata_qemu_only_clh_override.
  kata-clh = pkgs.kata-runtime.overrideAttrs (old: {
    postInstall =
      (old.postInstall or "")
      + ''
        ln -s ${pkgs.cloud-hypervisor}/bin/cloud-hypervisor $out/bin/cloud-hypervisor
      '';
  });
  kataClhConfig = "${kata-clh}/share/defaults/kata-containers/configuration-clh.toml";

  # gVisor (runsc): shim `containerd-shim-runsc-v1`, type `io.containerd.runsc.v1`.
  # kata-qemu: shim `containerd-shim-kata-qemu-v2`, type `io.containerd.kata-qemu.v2`,
  #   ConfigPath → the qemu toml nixpkgs already patched (kata-images kernel/rootfs,
  #   virtiofsd, QEMUPATH baked in). No /etc/kata-containers needed.
  # kata-clh: shim `containerd-shim-kata-clh-v2`, type `io.containerd.kata-clh.v2`,
  #   ConfigPath → the clh toml from the cloud-hypervisor-patched override above.
  #   Boots leaner/faster than QEMU — preferred for the AI-coding-layer ephemeral
  #   sessions. Same /dev/kvm story as kata-qemu (nested-virt INSIDE a kata pod is
  #   NOT achievable with the stock guest kernel — see the runc-kvm note and
  #   project_kata_guest_kernel_no_nested_kvm).
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

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-clh]
      runtime_type = "io.containerd.kata-clh.v2"

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-clh.options]
      ConfigPath = "${kataClhConfig}"

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

  # containerd only reads the drop-in below at *startup*. The drop-in is reached
  # via a tmpfiles symlink, and changing its target does NOT alter the k3s unit
  # definition — so `nixos-rebuild switch` would update the symlink but leave the
  # running containerd on its old runtime config (RuntimeClass objects would
  # apply, but their containerd handlers would be missing until a manual restart).
  # Tie the unit's restart to the runtimes file so any change to the registered
  # runtimes bounces k3s and containerd re-reads them on rebuild.
  systemd.services.k3s.restartTriggers = [extraRuntimes];

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
    (mkRuntimeClass "kata-clh")
    (mkRuntimeClass "runc-kvm")
  ];
}
