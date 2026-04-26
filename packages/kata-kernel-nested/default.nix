# Linux kernel for Kata guest VMs with KVM-host support compiled in.
#
# The default Kata kernel only has CONFIG_KVM_GUEST=y — it can run AS a KVM
# guest but cannot host KVM workloads. Inner QEMU (e.g. NixOS test driver
# under nix flake check) silently falls back to TCG software emulation,
# which makes VM-spawning tests effectively hang.
#
# This kernel is the standard nixpkgs Linux kernel (tracks the current
# default LTS) with KVM and the virtio drivers needed for boot flipped
# from module to built-in, so /dev/kvm is created at boot without needing
# to load modules from the (kernel-version-mismatched) Kata rootfs.
{
  linuxPackages,
  lib,
}: let
  builtinSymbols = import ./builtin-symbols.nix;
in
  linuxPackages.kernel.override {
    structuredExtraConfig =
      lib.genAttrs builtinSymbols (_: lib.kernel.yes);
  }
