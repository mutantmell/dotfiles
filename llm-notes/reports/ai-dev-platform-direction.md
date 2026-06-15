# AI Dev Platform Direction

Date: 2026-06-15

## Summary

The dev-machine platform should continue to optimize for isolated,
review-gated AI-assisted development:

- Agents work in locked-down, ephemeral development environments.
- Agents can propose changes through Git, but humans review and merge.
- CI provides required feedback before merge.
- GitOps or fleet activation handles deployment after merge.
- The agent runtime does not get direct access to the services it is changing.

The current KubeVirt + DevPod design already fits this shape. The useful
follow-ups are mostly around CI feedback, session inventory, and future
lifecycle boundaries, not a new web IDE surface.

## Adopt

- **CI feedback loop for agents.** Agents should be able to see whether PR
  checks passed, read review comments, inspect compact failure summaries, and
  respond to lifecycle comments. This is tracked in
  `llm-notes/plans/cicd-fleet-activation-plan.md` and
  `llm-notes/specs/cicd-fleet-management.md`.
- **Codified homelab maintenance workflows.** Add playbooks for recurring
  maintenance tasks that fit AI assistance well: dependency updates, service
  healthcheck audits, network-policy review, release-note summarization, and
  GitOps rollout checks.
- **Better session inventory.** Improve `dev-machine list` and related wrapper
  output before adding any dashboard. The useful view is VM slot, KubeVirt
  status, DevPod provider, workspace/session hints, and attach/editor targets.
- **First-class SSH/editor paths.** Keep SSH as the primary operator/editor
  interface. Document and smooth direct `dev-N.internal` access and proxied
  access through edith for SSH-capable editors.

## Keep As Non-Goals

- **Browser IDE as a default surface.** A richer web/mobile UI is not a clear
  capability gap for a single-operator workflow. Modern editors can use SSH
  remoting, and terminal attach already works through `tssh`/`zellij`.
- **Root in the agent session as a convenience default.** The VM is the primary
  security boundary, but the agent should still run as a non-root devcontainer
  user. Operator tools and cluster credentials stay outside the agent runtime.
- **A separate always-on dev platform control plane.** Continue to prefer
  repo-owned text, DevPod, `devcontainer.json`, and small wrapper tooling over
  an additional mutable web/database platform unless multi-user requirements
  appear.

## Existing Strengths To Preserve

- **Isolation.** The dev-machine uses an ephemeral KubeVirt VM on the cluster
  VLAN, multus-only macvtap networking, router-enforced egress, and a non-root
  inner devcontainer.
- **Credential lifecycle.** The wrapper mints a per-session Forgejo SSH key for
  the bot account, injects only that key into the sandbox, disables operator SSH
  agent forwarding, and revokes the key on teardown.
- **Build/test fidelity.** The VM host daemon supports Nix sandboxing,
  uid-range builds, cgroups, and `/dev/kvm` for NixOS VM tests.
- **Operator/tool separation.** `kubectl`, `virtctl`, DevPod, registry push
  tooling, and cluster credentials stay on the operator side instead of inside
  the agent container.

## End-State Guidance

The next meaningful improvements are:

1. Build the CI/PR feedback loop for agents.
2. Improve SSH/editor ergonomics and inventory output.
3. Preserve the future extraction path where a lower-level KubeVirt lifecycle
   tool owns machines, and a custom DevPod provider becomes a thin integration
   layer on top.
