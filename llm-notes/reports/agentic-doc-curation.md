# Agentic Doc Curation Report

Date: 2026-06-11

Scope: `llm-notes/` only. No large deletions or archives were performed.

## Summary

This pass found several historical plans that are easy for an agent to
misread as current workflow guidance. The highest-risk patterns were:

- old plan steps that point only at `CLAUDE.md` for agent-facing
  documentation;
- raw `nix flake check` / `nix flake check --print-build-logs` snippets in
  completed plans;
- files in `done/` whose internal status still says "Planning" or otherwise
  reads like active work;
- dev-machine history that is mostly reconciled, but still contains older
  transport, network, and CI notes by design.

## Edited In Place

- `llm-notes/CONVENTIONS.md` now tells agents to treat historical plans as
  decision records, not live runbooks; not to treat `CLAUDE.md` references as
  exhaustive; and not to copy old validation commands blindly.
- `llm-notes/done/observability-stack-migration.md` now has a top curation note
  warning that its `Status: Planning` header is stale relative to its `done/`
  location.
- `llm-notes/done/openwrt-python-builder.md` now has a curation note warning
  that `openwrtBuildInfo`, `CLAUDE.md`, and raw flake-check references are
  historical.
- `llm-notes/done/openwrt-config-build-artifacts.md` now has a curation note
  warning that its documentation and validation snippets are plan-time context.
- `llm-notes/done/incus-module-overhaul.md` now has a curation note warning
  that the `CLAUDE.md` documentation step is not an exclusive agent guide.

## Deletion Or Archive Candidates

These are candidates only. They were not deleted because each may still have
some historical value.

### `llm-notes/done/observability-stack-migration.md`

Why: It is in `done/` but opens with `Status: Planning`, and much of the body
is a plan for services and migration phases. It can mislead agents into
thinking the old architecture choices and rollout steps are current.

Recommendation: Keep only if the migration reasoning is still useful. If
retained, consider a stronger status rewrite or a short "as-built differs"
appendix.

### `llm-notes/done/openwrt-python-builder.md`

Why: It describes the now-superseded `openwrtBuildInfo` interface and includes
plan-time instructions to update `CLAUDE.md` plus raw flake-check validation.

Recommendation: Keep as background for why the Python builder replaced
`nix-openwrt-imagebuilder`, but do not use it as current implementation
guidance. If its rationale is captured elsewhere, it is a reasonable archive
candidate.

### `llm-notes/done/openwrt-config-build-artifacts.md`

Why: It supersedes pieces of the previous OpenWrt builder plan but still reads
as an implementation checklist, including `CLAUDE.md` as a target file.

Recommendation: Keep if OpenWrt config artifact design history is valuable;
otherwise archive after confirming current OpenWrt app and flake outputs are
self-documenting.

### `llm-notes/done/incus-module-overhaul.md`

Why: It includes a plan-time step to document module architecture in
`CLAUDE.md`, which can be misread as the sole agent-facing source for that
convention.

Recommendation: Keep; the module split rationale is useful. The curation note
is likely enough.

### `llm-notes/shelved/migrate-scripts-to-typescript-deno.md`

Why: It is correctly shelved, but it includes future documentation steps that
target `CLAUDE.md` and says Deno tests would run in `nix flake check`.

Recommendation: Keep shelved. If resumed, update the validation and agent-doc
targets before implementation.

### `llm-notes/done/nixos-anywhere-integration-plan.md`

Why: It includes raw `nix flake check` validation snippets and old target
structure. It may still be useful as history but should not be followed as a
deployment runbook.

Recommendation: Keep only as historical migration context. Prefer current
deployment guides and active scripts for operator steps.

### `llm-notes/done/deploy-nixos-anywhere-vm-hosts.md`

Why: It contains raw `nix flake check` validation and identifies some path
patterns as possibly stale. This is exactly the kind of historical note an
agent can over-apply.

Recommendation: Keep as history if the VM-host deployment reasoning is useful;
otherwise archive after any durable lessons are moved to a current guide.

## Dev-Machine Notes

`llm-notes/done/ai-dev-machine-kubevirt-plan.md` is large, but its top status is
current and explicitly reconciles the major changes found during this pass:
network lockdown moved to router-enforced VLAN 51, bridge became macvtap, and
mosh became tssh/tsshd. No deletion is recommended from this pass.

`llm-notes/wip/workload-network-isolation-plan.md` also calls out that the
dev-machine/mobile critical path is executed, with remaining workload-isolation
work still tracked as WIP. That split appears intentional.
