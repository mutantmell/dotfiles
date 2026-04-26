# Kconfig symbols we require to be =y in the kata-kernel-nested kernel.
# Imported by both the kernel package (to flip the overrides) and the
# drift check in tests/default.nix (to grep the resulting .config).
[
  # Parents — must be =y for child =y options to take.
  "VIRTIO"
  "VSOCKETS"
  "SCSI"
  # KVM host (Intel-only; KVM_AMD pulls in KVM_AMD_SEV which breaks
  # nixpkgs's config checker on this kernel).
  "KVM"
  "KVM_INTEL"
  # Virtio drivers needed at boot, before any module loader runs.
  "VIRTIO_BLK"
  "VIRTIO_NET"
  "VIRTIO_CONSOLE"
  "VIRTIO_PCI"
  "VIRTIO_BALLOON"
  "VIRTIO_FS"
  "VIRTIO_VSOCKETS"
  "SCSI_VIRTIO"
  "FUSE_FS"
]
