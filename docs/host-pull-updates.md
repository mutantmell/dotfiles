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

Comin is selected over the assessed blob-flake/`system.autoUpgrade` alternative:
its signature verification, persistent release history, metrics and pause controls
avoid adding those features as custom scripts. Pin it before relying on features.

## Release safeguards to implement

- Use a separate trusted publisher or proven clean disposable execution boundary.
  The persistent local-backend PR worker cannot safely gain publishing secrets
  later merely because the job event changes.
- Sign candidate commits before CI tests them; promote that exact hash. Select
  compatible Comin/Flux verification after pinning versions. Independently provision
  trust keys with rotation overlap. Source signatures do not attest CI success;
  protected branch promotion is the deployment authorization boundary.
- Flux also follows `release`, with read-only credentials and committed per-cluster
  paths. Nix owns Flux bootstrap initially; Flux owns migrated resources. Its
  health/dependency controls order Kubernetes resources, not Comin host updates.
- Consumers may skip releases. Use backwards-compatible platform transitions or
  explicit readiness holds covering required hosts, paused/offline hosts and rejoin.
  Two commits or jitter alone do not enforce order.
- Nix dependency pins must constrain deployed bytes: image/OCI chart digests or
  exact verified immutable chart artifacts. CI-only hash checking is insufficient.
- Preserve Comin state under impermanence. Test cold source/evaluation failures,
  remote-builder restrictions and the `max-jobs = 0`/`preferLocalBuild` exception;
  this remains an intermediate model minimizing compilation, not full lockdown.
- Audit effective Attic per-cache retention and the possibly obsolete
  `retention-period` key. Protect complete current/recovery releases regardless of
  age; historical expiry is a separate capacity choice.
- Establish SQLite datastore plus server-token/identity recovery off-host before
  unattended k3s upgrades. Application and VM disk backups remain separate. Use
  supported sequential minor upgrades with add-on compatibility and health checks.
- Use native pause controls and existing monitoring for desired/running revision,
  failures, stale hosts and pending reboots. Recovery must work without k3s.

These are requirements for implementation and acceptance, not existing guarantees.

Implementation units: [fleet issues](work-tracking.md).
Contract and acceptance criteria: [fleet specification](design/fleet-delivery.md).
