# Planned NixOS pull updates

Status: agreed direction, not an installed service or production runbook.

The intended update path is reviewed PR → `main` → trusted Woodpecker validation
and host builds → complete closure publication to Attic on liberl/zeiss →
fast-forward promotion of protected `release` → Comin on enrolled hosts.

Comin will follow only `release`, with testing branches disabled. It still
performs local Nix evaluation. The implementation must restrict local and remote
compilation and prove that a cache miss postpones updates safely. Only trusted
CI may promote release or write the publication cache; PR jobs receive neither
credential. Promotion must identify the exact tested commit and never regress
because an older pipeline finishes late.

The initial target is erebonia/calvard and ideally liberl. Physical-host rollout
and tighter access restrictions await working, tested KVM/out-of-band recovery.
Disposable-VM validation can proceed now. Deployment history alone is not proof
of health-based or failed-boot rollback. A shared release branch does not serialize
host updates: maintenance/pause controls and health observation must be validated
before unattended rollout. Existing operator deployment tools remain the recovery
and provisioning path.

NixOS owns the host and k3s runtime/bootstrap; Flux is the intended Kubernetes
resource reconciler once its Git source is wired. Host updates and recovery must
work while k3s is unavailable. Cluster upgrades additionally require datastore
backup/recovery and cluster health checks, beyond OS-generation rollback.

The complete path must remain open source and self-hostable. NATS and a custom
coordinator are outside the initial scope. nix-fleet is a possible later updater,
not a dependency on a delivery date. Shared object storage is a separate project
with multiple potential consumers, not a prerequisite for this workflow.

A CI-published HTTPS tarball flake with built-in `system.autoUpgrade` is also
under investigation as a smaller alternative; no change of updater has been
selected. End-to-end activation/recovery and publication guarantees still need
validation. See the alternative note in the plan and the upstream
[NixOS auto-upgrade module](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/tasks/auto-upgrade.nix).

Implementation checklist: [fleet activation plan](../llm-notes/wip/cicd-fleet-activation-plan.md).
Contract and acceptance criteria: [fleet specification](../llm-notes/specs/cicd-fleet-management.md).
