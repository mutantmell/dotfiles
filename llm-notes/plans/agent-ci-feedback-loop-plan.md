# Agent CI Feedback Loop Plan

> **Status:** Planning.
>
> This plan defines the agent-facing workflow for PR creation, CI feedback, and
> local failure reproduction now that Woodpecker CI is working for the dotfiles
> repository. It is the target replacement for AGit as the preferred agent PR
> workflow, but AGit remains the default until the branch-push and API credential
> model below is implemented and validated.

## Goal

Move routine agent development toward this loop:

1. The agent runs quick checks locally.
2. The agent pushes a constrained normal branch and opens or updates a Forgejo
   PR.
3. Forgejo triggers Woodpecker on the PR.
4. Woodpecker reports status back to Forgejo.
5. A trusted reporter publishes compact CI failure summaries into the PR.
6. The agent reads PR state, review comments, and CI summaries through `tea`.
7. The agent reproduces individual failing checks locally and pushes a fix.

The agent should have one auditable forge integration: Forgejo through `tea`.
The agent should not need direct Woodpecker API credentials or direct
Woodpecker CLI access for normal CI diagnosis.

## Non-Goals

- Replacing Woodpecker with Forgejo Actions.
- Giving agents deployment, cluster, registry, Woodpecker admin, or repository
  admin permissions.
- Making dev-machine instances run the full CI suite by default.
- Solving KVM-capable Woodpecker jobs in this feature slice.
- Removing AGit before the replacement workflow has proven reliable.

## Current State

- Woodpecker is deployed as the CI control plane on `saint-arkh`.
- Build execution uses the Kubernetes backend on erebonia.
- The currently proven CI lane runs `./scripts/agent-preflight.sh --quick`.
- This is a narrow proof lane, not full CI coverage. It does not yet prove the
  full check matrix, KVM-capable NixOS VM tests, or mature artifact output.
- The repo has agent-friendly local commands:
  - `agent-preflight-quick`
  - `agent-preflight-full`
  - `agent-checks <check>`
  - `agent-build-check <check>`
- AGit currently opens PRs without requiring a Forgejo API token.
- `tea` is not currently installed in the dev-machine PATH.
- `tea` 0.14.0 is available from nixpkgs and supports:
  - PR creation and editing;
  - PR listing and JSON output;
  - issue/PR comments;
  - review comments;
  - a `ci` PR field;
  - authenticated raw Forgejo API calls through `tea api`.

## Design

### Agent-facing integration

Use `tea` as the only normal agent-facing Forgejo integration.

The target workflow uses normal git branches instead of AGit refs:

```bash
git switch -c agent/<topic>
./scripts/agent-preflight.sh --quick
git push origin HEAD
tea pr create --head agent/<topic> --base main --title "<title>" --description "<body>"
```

For updates, the agent pushes to the same branch and uses `tea` only for PR
metadata, comments, and lifecycle communication.

Do not make this the default until Forgejo-side branch constraints have been
tested. The current AGit workflow remains the fallback and operational default
until then.

Useful direct commands:

```bash
tea pr list --fields index,title,state,head,base,mergeable,ci --output json
tea pr <id> --comments --output json
tea pr review-comments <id> --output json
tea comment <id> "<message>"
```

Thin wrappers may be added later for ergonomics, but they should wrap `tea` and
repo-local commands rather than reimplementing a Forgejo client.

### Credentials

Split branch push and PR API access.

Branch push credential:

- SSH deploy key for branch pushes only.
- Must not be able to write `main`.
- Must not be able to create or update tags.
- Must not be able to delete protected branches.
- Should be restricted to an agent namespace such as `refs/heads/agent/*` if
  Forgejo can enforce that directly; otherwise use a server-side git hook,
  brokered push path, or keep AGit as the default.
- Force-push policy should be explicit. It is acceptable for active agent PR
  branches, but not for protected branches or tags.
- Rotation and revocation should remain per-session or otherwise short-lived, as
  with the current dev-machine push key model.

Forgejo API credential:

- Forgejo token for `tea`: scoped to the dotfiles repository, with only the
  permissions needed for the selected API workflow.

The token should not grant repository administration, package/registry access,
deployment access, or site administration. If Forgejo's available scope model
requires broader write access than ideal, prefer a small trusted broker service
over putting a broad token directly into the dev-machine.

There are two acceptable API models:

- **Direct-token model:** only if Forgejo can issue a repository-limited token
  with the exact practical permissions needed for PR creation/update, PR reads,
  review/comment reads, and PR comment writes.
- **Broker model:** required if PR creation or update needs broad
  `write:repository` capability. The dev-machine talks to a narrow internal
  service that exposes only create/update/read/comment operations for agent PRs.

Do not conflate the reporter credential with the agent `tea` credential. The
reporter needs write access to a sticky CI summary comment; the agent needs only
the PR operations selected above.

### `tea` token materialization

`tea` stores login state under the user config directory by default. The
implementation must define how that state is created and destroyed.

Required properties:

- Set an explicit `XDG_CONFIG_HOME` or `TEA_CONFIG_HOME` equivalent if `tea`
  supports one; otherwise document and secure the default path.
- Store the token in an ephemeral dev-machine location with `0600` file mode.
- Do not bake the token into Nix derivations, devcontainer images, dotfiles, or
  shell wrapper text.
- Do not print the token in setup logs.
- Wipe the token/config on dev-machine teardown or session revocation.
- Exclude the token path from rescue bundles, debug archives, and copied
  workspace artifacts.
- Add smoke checks for expected presence only when the feature is enabled, and
  absence otherwise.

### CI feedback path

Woodpecker remains the CI system, but agents do not query Woodpecker directly.

Required flow:

1. Woodpecker runs PR checks.
2. CI emits `check-summary.json` and `check-summary.md` for each head SHA.
3. A trusted reporter outside the untrusted build step reads Woodpecker result
   data and posts or updates one sticky PR comment in Forgejo.
4. Agents read that comment through `tea`.

The reporter can run beside the Woodpecker server on `saint-arkh`, or as another
trusted service with narrowly scoped access to:

- read Woodpecker pipeline state/logs;
- write PR comments in Forgejo.

Do not mount a Forgejo write/comment token into untrusted PR build steps.

PR feedback lanes should run without deployment, signing, cache-push, NATS, or
other high-value secrets. Treat all build output and log text as untrusted input
before copying it into Forgejo comments.

### CI summary format

The sticky PR comment should be stable enough for both humans and agents.
The source of truth is the CI artifact pair:

- `check-summary.json` — structured status, failed checks, local reproduction
  commands, relevant log tails, and full log/artifact URLs.
- `check-summary.md` — the human-readable rendering that the trusted reporter
  can copy into the sticky PR comment.

The reporter should locate summaries by repository, head SHA, Woodpecker
pipeline number, and workflow/step identity. The PR comment is a projection of
the artifact, not the only copy of the data.

Recommended initial shape:

````markdown
<!-- dotfiles-ci-summary:v1 sha=<head-sha> -->

CI: failed
Head: <sha>
Pipeline: https://woodpecker.internal/repos/...

Failed checks:
- network-registry
  Reproduce: ./scripts/run-checks.sh network-registry
  Full log: <woodpecker step URL or artifact URL>
  Log tail:
  ```text
  ...
  ```
````

If the summary grows, include a fenced JSON block with the same data:

```json
{
  "schema": "dotfiles-ci-summary:v1",
  "head": "<sha>",
  "status": "failed",
  "pipeline_url": "https://woodpecker.internal/repos/...",
  "failed_checks": [
    {
      "name": "network-registry",
      "reproduce": "./scripts/run-checks.sh network-registry",
      "log_url": "https://woodpecker.internal/...",
      "log_tail": "..."
    }
  ]
}
```

Every failed check should map to a repo-local reproduction command.

Log tails copied into summaries must be bounded and redacted:

- hard cap per check, initially 100-200 lines or a byte-equivalent limit;
- redact known secret-looking names and values before posting;
- omit environment dumps by default;
- mark full Woodpecker log links as privileged/internal if they require access
  beyond normal Forgejo PR visibility.

### Local reproduction

Agents should keep local validation narrow:

```bash
./scripts/agent-preflight.sh --quick
./scripts/run-checks.sh <check>
nix build .#checks.x86_64-linux.<check> --print-build-logs
```

Full preflight remains available, but CI should become the durable gate for
broad and expensive validation.

## Implementation Plan

### Phase 1: Add `tea` to dev-machine

- Add `tea` to the dev-machine tool package.
- Define a feature gate, for example `dev-machine.agentForgejoApi.enable`.
- Add dual-mode smoke behavior:
  - when disabled, `tea` and `gh` remain absent as today;
  - when enabled, `tea --version` works and the configured token path has safe
    ownership/mode;
  - `gh`, operator tools, cluster tools, and registry credentials remain absent.
- Document the intended `tea` workflow in `docs/dev-machine.md`.
- Remove or revise the existing "do not look for tea" guidance once the new
  credential model is implemented.

### Phase 2: Add Forgejo API credential plumbing

- Decide whether the token is injected directly into the dev-machine or exposed
  through a trusted local broker.
- Prefer a repository-limited token if the needed `tea` operations fit Forgejo's
  scoped token model.
- Test the actual Forgejo token scopes for:
  - PR create;
  - PR edit;
  - PR read;
  - issue/PR comment read;
  - issue/PR comment write;
  - review comment read.
- If those operations require broad repository write access, make the broker
  mandatory before replacing AGit.
- Configure `tea` non-interactively for `https://forgejo.internal`.
- Keep the `tea` token separate from the SSH push key.
- Ensure the token is not written into the repo, Nix store, shell history, or
  build logs.

### Phase 3: Switch default PR creation to normal branches

- Validate branch-push constraints before changing the default workflow:
  - `main` push rejected;
  - tag creation rejected;
  - branch deletion rejected unless deliberately allowed for `agent/*`;
  - force-push behavior matches policy;
  - only `agent/*` or another documented namespace is writable.
- Add docs or wrappers for:
  - create branch;
  - quick preflight;
  - push branch;
  - create PR with `tea pr create`;
  - update existing PR by pushing to the same branch.
- Keep AGit documented as a fallback until this path works end to end.
- Confirm Woodpecker receives PR webhook events for `tea`-created PRs and
  subsequent branch pushes.

### Phase 4: Emit compact CI summaries

- Extend the CI quick lane so check execution produces `check-summary.json` and
  `check-summary.md`.
- Make failures include:
  - check name;
  - exact local reproduction command;
  - failing command or phase;
  - relevant log tail;
  - full log/artifact URL.
- Define artifact location, schema version, retention expectations, and reporter
  lookup rules.
- Add summary redaction and size limits before posting to Forgejo.
- Start with quick preflight results, then extend to sharded full checks later.

### Phase 5: Add trusted Forgejo CI reporter

- Implement a reporter outside untrusted PR build steps.
- The reporter should:
  - identify the PR and head SHA for a completed pipeline;
  - fetch Woodpecker result data/log tails;
  - create or update the sticky `dotfiles-ci-summary:v1` PR comment;
  - avoid duplicate comments on reruns;
  - clearly mark stale summaries when the PR head changes.
- Store reporter credentials through sops-nix or another host-side secret path.
- Keep reporter credentials out of Woodpecker build pods unless the pod is a
  trusted reporter-only job that never checks out untrusted PR code.

### Phase 6: Agent ergonomics

Only after the raw `tea` flow works, add thin wrappers if they reduce repeated
manual parsing:

- `agent-pr-status`: print current PR, Forgejo CI state, and latest sticky CI
  summary.
- `agent-pr-comments`: print review and lifecycle comments.
- `agent-pr-comment`: post a PR comment through `tea`.

These wrappers should be small shell scripts or package scripts around `tea`,
`jq`, and local repo commands. They should not become a separate Forgejo client.

### Phase 7: Merge gates

- Configure branch protection on `main` to require the Woodpecker status checks.
- Require human review before merge.
- Keep direct admin override available for emergency repair when CI is down.

## Validation

Minimum end-to-end test:

1. Start from a dev-machine with the new `tea` credential.
2. Create a normal branch.
3. Make a harmless change that passes quick checks.
4. Run `./scripts/agent-preflight.sh --quick`.
5. Push the branch.
6. Open a PR with `tea pr create`.
7. Confirm Woodpecker runs from the PR event.
8. Confirm Forgejo exposes CI state through `tea pr ... --fields ci`.
9. Introduce a controlled failing check.
10. Confirm the reporter posts the sticky CI summary.
11. Confirm the agent can read the summary through `tea`.
12. Run the reported reproduction command locally.
13. Push a fix and confirm the sticky comment updates to success or stale-free
    current state.

## Open Questions

- Does Forgejo's repository-limited token model allow exactly the needed read PR
  and write comment operations without broader repository write access?
- Should the reporter be a systemd service on `saint-arkh`, a Woodpecker
  extension, or a separate internal service?
- Can Woodpecker expose enough stable step URLs/artifact URLs for the summary,
  or should the reporter copy log tails into Forgejo and treat full log URLs as
  best-effort links?
- Should lifecycle commands such as `agent: retry checks` be handled by active
  agent polling only, or should a later webhook-to-queue path notify active
  sessions?
- What exact status check names should branch protection require once the CI
  lane is sharded?

## Addendum: Agent Skill Changes

The repo workflow guidance is not enough on its own. The active Codex skill and
plugin guidance should change once the `tea` workflow is implemented, otherwise
agents will continue following the old AGit-only model.

### Required skill updates

Update the Forgejo/PR workflow skill currently used by this repo's agent
profile. The new skill should:

- Treat AGit as a fallback, not the default, once the `tea` path is validated.
- Prefer normal branch PRs under the approved agent branch namespace.
- Require local quick validation before opening or updating a PR:

  ```bash
  ./scripts/agent-preflight.sh --quick
  ```

- Use `tea` for PR create/update/status/comment operations when the Forgejo API
  credential feature is enabled.
- Avoid direct Woodpecker API/CLI use in normal agent sessions.
- Read CI feedback from Forgejo PR state and the sticky
  `dotfiles-ci-summary:v1` comment.
- Reproduce failing checks locally with the exact command from the CI summary.
- Preserve the rule that irreversible or outward-facing actions beyond
  opening/updating a PR need human confirmation.

The skill should include a simple decision tree:

1. If `tea` is configured and the branch credential model is enabled, use the
   normal branch workflow.
2. If `tea` is unavailable but AGit push works, use the AGit fallback.
3. If neither is available, stop and report that the dev-machine lacks a PR
   submission credential.

### Useful new skill content

Add a small "CI feedback loop" section to the skill:

- `tea pr list --fields index,title,state,head,base,mergeable,ci --output json`
  finds candidate PRs and their Forgejo-visible CI state.
- `tea pr <id> --comments --output json` retrieves lifecycle comments and the
  sticky CI summary.
- `tea pr review-comments <id> --output json` retrieves review comments.
- `tea comment <id> "<message>"` posts concise status updates.
- The agent should parse the latest non-stale `dotfiles-ci-summary:v1` comment
  matching the current head SHA before deciding which local check to run.

The skill should warn that Forgejo's `ci` field is only a status signal. The
actionable failure detail lives in the sticky CI summary comment generated by
the trusted reporter.

### Beneficial wrapper-aware guidance

If Phase 6 adds wrappers such as `agent-pr-status`, update the skill to prefer
those wrappers over raw `tea` commands. Until then, raw `tea` commands are the
source of truth.

Do not add a separate Woodpecker skill for ordinary agent use. If a future
operator/debugging skill needs Woodpecker access, keep it separate from the
normal development workflow and require explicit operator context.

### Repo-local instructions to update

When the workflow switches, update:

- `AGENTS.md`:
  - replace "Submitting Changes With AGit" with a `tea` normal-branch workflow;
  - retain a short AGit fallback section while it remains supported;
  - remove the instruction not to look for `tea` or PR API tokens.
- `docs/dev-machine.md`:
  - document when the Forgejo API credential feature is enabled;
  - document where `tea` config lives and how it is cleaned up;
  - document the expected PR/CI feedback loop.
- `scripts/dev-machine-smoke.sh`:
  - keep asserting `tea` absence when the feature is disabled;
  - assert `tea` presence and token-file permissions when enabled.
