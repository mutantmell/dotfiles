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

  # ──────────────────────────────────────────────────────────────────────────
  # Nested-virtualization guest kernel for kata-clh.
  #
  # Goal: expose /dev/kvm INSIDE a kata-clh pod so the pod can boot its own
  # nested VM (the dev-workspace use case runs this repo's VM test suite,
  # `pkgs.testers.nixosTest`, which needs /dev/kvm). All the host- and
  # hypervisor-layer prerequisites are already met:
  #   • erebonia is Intel (i5-1135G7) with `kvm_intel nested=1` on the host.
  #   • cloud-hypervisor defaults `--cpus nested=on` on x86-64, and kata passes
  #     no CPU override, so VMX is ALREADY surfaced into the kata guest.
  # The single remaining blocker is the kata GUEST KERNEL config: the stock
  # nixpkgs kata guest kernel (kata-images, kernel 6.18.15) is a prebuilt binary
  # whose shipped `config-6.18.15-189` has `# CONFIG_VIRTUALIZATION is not set`,
  # which gates the entire KVM submenu — so there is no /dev/kvm in-guest.
  #
  # The fix is to rebuild JUST the guest kernel from vanilla kernel.org 6.18.15
  # using the stock kata config with three symbols flipped on, then repoint the
  # kata-clh toml's `kernel =` line at it. kata-qemu is left on the prebuilt
  # kernel untouched.
  #
  # Why a from-source rebuild is safe here:
  #   • kata's downstream 6.18.x patches are trivial (a single fs/dax patch,
  #     nothing KVM/virt related), so vanilla 6.18.15 + the patched config boots
  #     fine as a kata guest — we do NOT need to reproduce kata's patch series.
  #   • The guest kernel is fully MONOLITHIC (`CONFIG_MODULES is not set`, zero
  #     `=m` symbols), so there is no /lib/modules to match against the prebuilt
  #     rootfs/kata-agent. Swapping the kernel does NOT decouple it from the
  #     stock rootfs/agent (the `-189` suffix is kata's build tag, not a
  #     LOCALVERSION the rootfs depends on).
  # See project_kata_guest_kernel_no_nested_kvm and
  # project_nixpkgs_kata_qemu_only_clh_override.

  kataImages = pkgs.kata-runtime.kata-images;
  kataKernelVersion = "6.18.15";
  # The stock guest kernel .config shipped alongside the prebuilt vmlinux.
  stockKataKernelConfig = "${kataImages}/share/kata-containers/config-${kataKernelVersion}-189";

  # Patched config: enable the three symbols that ungate /dev/kvm.
  #   CONFIG_VIRTUALIZATION=y — the submenu gate; everything below depends on it.
  #   CONFIG_KVM=y            — the KVM core.
  #   CONFIG_KVM_INTEL=y      — Intel VMX backend (erebonia is Intel; no AMD sym).
  # All of these symbols' Kconfig dependencies are already =y in the stock config
  # (verified: VIRTUALIZATION, KVM, KVM_INTEL select/depend on X86_LOCAL_APIC,
  # IA32_FEAT_CTL, IRQ_BYPASS_MANAGER, HIGH_RES_TIMERS, EVENTFD, X2APIC — present
  # or auto-selected). CONFIG_PVH=y is ALSO already set in the stock config, which
  # is mandatory: cloud-hypervisor boots via the PVH boot protocol and the kernel
  # must carry the PVH ELF note (the stock vmlinux.container boots under clh, so
  # PVH is necessarily present — confirmed by grep).
  #
  # Robust rewrite: for each symbol, strip ANY existing line (the
  # `# CONFIG_X is not set` form for VIRTUALIZATION, and KVM/KVM_INTEL which are
  # absent entirely because VIRTUALIZATION gates them), then append `=y`.
  patchedKataKernelConfig =
    pkgs.runCommand "kata-clh-nested-kernel.config" {
      src = stockKataKernelConfig;
    } ''
      cp "$src" .config
      chmod +w .config
      for sym in VIRTUALIZATION KVM KVM_INTEL; do
        # Drop both the "=value" and the "is not set" forms, if present.
        sed -i -e "/^CONFIG_$sym=/d" -e "/^# CONFIG_$sym is not set\$/d" .config
        echo "CONFIG_$sym=y" >> .config
      done
      cp .config "$out"
    '';

  # Build the custom guest kernel from vanilla kernel.org 6.18.15 with the
  # patched config. linuxManualConfig reads the configfile to autodetect the
  # config attrs (module-ness etc.); since our configfile is a derivation we must
  # set allowImportFromDerivation = true so the builder may readFile it.
  nestedKataKernel = pkgs.linuxManualConfig {
    version = kataKernelVersion;
    src = pkgs.fetchurl {
      url = "mirror://kernel/linux/kernel/v6.x/linux-${kataKernelVersion}.tar.xz";
      hash = "sha256-fHFiFsPEE07Q3mkZVwHmd1d7vN05efMxwYKs0Gvy8XA=";
    };
    configfile = patchedKataKernelConfig;
    allowImportFromDerivation = true;
  };

  # cloud-hypervisor cannot boot the compressed bzImage that nixpkgs' kernel
  # build installs to $out — it needs the uncompressed PVH `vmlinux` ELF. For a
  # MODULAR kernel, nixpkgs copies `vmlinux` into the `$dev` output (this is the
  # `${kernel.dev}/vmlinux` path microvm.nix's cloud-hypervisor runner consumes —
  # lib/runners/cloud-hypervisor.nix). But our kernel is MONOLITHIC, so nixpkgs
  # never creates a `$dev` output and never copies `vmlinux` — that copy lives
  # inside `postInstall = optionalString isModular …` in
  # pkgs/os-specific/linux/kernel/build.nix.
  #
  # We therefore add our own postInstall to lift `vmlinux` out of the build tree
  # ($buildRoot, where the kernel Makefile leaves the linked ELF) into $out. The
  # kernel's own preFixup already strips $out/vmlinux if it exists, so dropping it
  # there is the idiomatic slot. We then reference $out/vmlinux directly — the
  # same ELF microvm.nix feeds to clh via $dev/vmlinux, just relocated to $out
  # because this build has no $dev.
  #
  # RESIDUAL UNCERTAINTY (operator must validate by building): this extraction
  # path is inferred from nixpkgs build.nix (the modular branch does exactly
  # `cp vmlinux $dev/` from $buildRoot, and preFixup expects $out/vmlinux) and
  # mirrored from microvm.nix's clh runner. It is not provable by eval alone.
  nestedKataKernelVmlinux = nestedKataKernel.overrideAttrs (old: {
    postInstall =
      (old.postInstall or "")
      + ''
        # $buildRoot is set by manual-config's configurePhase and holds the
        # linked, uncompressed vmlinux ELF (PVH-noted, what clh needs).
        cp "$buildRoot/vmlinux" "$out/vmlinux"
      '';
  });
  nestedKataKernelPath = "${nestedKataKernelVmlinux}/vmlinux";

  # Generate the kata-clh toml from the override's shipped one, repointing ONLY
  # the `kernel =` line at our nested-virt vmlinux. Everything else (image,
  # virtiofsd, the self-referential `path`/`valid_hypervisor_paths` to this
  # override's own $out, kernel_params, …) is kept byte-for-byte. We source the
  # toml from the kata-clh override (not stock kata-runtime) so `path` resolves to
  # the out that actually has the cloud-hypervisor symlink.
  kataClhConfig =
    pkgs.runCommand "configuration-clh-nested.toml" {
      src = "${kata-clh}/share/defaults/kata-containers/configuration-clh.toml";
    } ''
      sed -E 's|^(kernel = ).*$|\1"${nestedKataKernelPath}"|' "$src" > "$out"
    '';
  # ──────────────────────────────────────────────────────────────────────────

  # gVisor (runsc): shim `containerd-shim-runsc-v1`, type `io.containerd.runsc.v1`.
  # kata-qemu: shim `containerd-shim-kata-qemu-v2`, type `io.containerd.kata-qemu.v2`,
  #   ConfigPath → the qemu toml nixpkgs already patched (kata-images kernel/rootfs,
  #   virtiofsd, QEMUPATH baked in). No /etc/kata-containers needed.
  # kata-clh: shim `containerd-shim-kata-clh-v2`, type `io.containerd.kata-clh.v2`,
  #   ConfigPath → the clh toml generated above, repointed at our nested-virt
  #   guest kernel. Boots leaner/faster than QEMU — preferred for the
  #   AI-coding-layer ephemeral sessions. UNLIKE kata-qemu, kata-clh DOES get
  #   /dev/kvm in-guest now: the custom guest kernel ungated VIRTUALIZATION/KVM/
  #   KVM_INTEL, and clh already surfaces VMX (--cpus nested=on). kata-qemu stays
  #   on the stock kernel and has NO in-guest /dev/kvm (see
  #   project_kata_guest_kernel_no_nested_kvm); for the runc path see runc-kvm.
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
