# Proposed persistent workstation lifecycle

Status: selected design for edith/trista migration; not implemented or live-accepted. The existing workstations remain Incus guests. These rules preserve the original migration's ownership and private bootstrap boundaries.

## Ownership

| Surface                           | Owner                         | Boundary                                                                                                                  |
| --------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Long-lived VM shell               | Flux                          | VM/run strategy, CPU/RAM, disks/PVC references, network attachments and snapshot policy; no guest OS activation           |
| Import, initial seed and recovery | One-shot operator provisioner | Stops/fences the VM, imports or restores a disk, seeds private files, validates, then exits; no continuous reconciliation |
| Guest system closure              | Pinned Comin inside the guest | Follows the explicitly approved verified release; never creates/deletes VM resources                                      |
| Private bootstrap identities      | Operator passage store        | Supplies the private guest age/SSH/enrollment identities out of band                                                      |
| Ordinary guest service secrets    | In-guest sops-nix             | Decrypts with the private identity already seeded into the guest                                                          |

Standalone user home-manager state remains user-managed where intended; guest system convergence must not silently take it over. Host rebuilds must no longer be the ordinary guest OS update trigger. Ephemeral dev-machine VMs have a different lifecycle and do not inherit this persistent-workstation contract.

## Offline private identity delivery

The provisioner must stop the VM and ensure the destination disk/static PVC has no competing writer before seeding. Preserve the guest-visible age identity path **`/static/var/lib/sops-nix/key.txt`** with restrictive ownership/mode. Retarget the existing `setup-guest.sh --output-dir` private tree into the guest disk or a dedicated static volume; reuse passage identities and preserve key-before-certificate convergence. Remove transient operator staging and any temporary attachment jobs after success, and make interruption/retry safe.

Do not deliver this root identity through cloud-init, configDrive, KubeVirt Secret volumes, Kubernetes Secrets, Flux SOPS, committed manifests, or a reusable base image. The decision is about trust ownership, not a claim that Flux lacks decryption support. Neither plaintext nor a second standing key capable of decrypting the guest root identity belongs in cluster desired state. Flux may hold public SSH access keys, network metadata and appropriately scoped image-pull credentials; those are distinct from the guest decryption root.

Offline seeding does not make the storage or virtualization administrator unable to inspect a VM disk. The boundary prevents adding a standing Kubernetes/Flux secret-distribution root; cluster/storage administrator access remains part of the infrastructure trust model. A temporary privileged disk-attachment mechanism needs explicit operator control, bounded lifetime and cleanup rather than a continuously available decryption service.

## Guest release enrollment and migration overlap

The [fleet release contract](fleet-delivery.md) applies only after explicit workstation enrollment. Add each guest to the trusted CI toplevel/complete-closure publication gate before it follows protected `release`. Pin Comin, set the exact remote/hostname, provision signature trust independently, disable testing branches and persist updater history under impermanence. Test cold evaluation/source/cache failures, local and remote compilation restrictions, pause controls, service/reboot failures and recovery; deployment history alone does not establish automatic rollback.

Use the pinned updater's `machineId` safeguard and explicit pause/fencing controls during migration. A cloned disk must not cause the old Incus instance and new KubeVirt guest to converge as the same host unintentionally. Validate overlap in isolation; only one instance may use the production hostname/address/identity at a time. Keep the stopped Incus disk and operator deployment/recovery route until acceptance. The one-shot provisioner does not become another steady-state updater.

Implementation and acceptance: [private provisioning](https://forgejo.internal/mutantmell-net/dotfiles/issues/255), [guest updates](https://forgejo.internal/mutantmell-net/dotfiles/issues/261), [edith cutover](https://forgejo.internal/mutantmell-net/dotfiles/issues/258), [trista cutover](https://forgejo.internal/mutantmell-net/dotfiles/issues/259).
