# Agent CI Feedback Loop Plan

> **Status:** Superseded.
>
> Superseded on 2026-06-26 by
> `llm-notes/plans/agent-ci-readonly-woodpecker-plan.md`. The default agent CI
> feedback path should use Forgejo branch protection plus read-only Woodpecker
> log access before adding sticky PR comment reporter machinery.
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
- Iteration 1 adds `tea` to the dev-machine PATH, but does not yet provision a
  Forgejo API token or switch the default PR workflow away from AGit.
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
Use Woodpecker's built-in Forgejo integration for the normal commit/PR status:
pending, success, failure, and the link back to the Woodpecker run. That status
is the merge-gate signal and should be what branch protection requires.

Do not expect the built-in status to carry rich, agent-actionable failure
detail. In a GitHub Checks-style system, the most integrated rich surface would
be native check-run annotations or a Markdown check summary. Forgejo +
Woodpecker's portable baseline is narrower: commit status plus a details link.
For this stack, the idiomatic rich-feedback surface is therefore a single
bot-managed sticky PR comment, with the structured artifact as the source of
truth.

Required flow:

1. Woodpecker runs PR checks.
2. Woodpecker reports normal status back to Forgejo for the head commit.
3. CI emits `check-summary.json` for each head SHA.
4. A trusted reporter outside the untrusted build step reads Woodpecker result
   data and posts or updates one sticky PR comment in Forgejo.
5. Agents read Forgejo PR state through `tea`: use the built-in CI status for
   pass/fail/mergeability, then use the sticky comment for concrete next steps.

The reporter can run beside the Woodpecker server on `saint-arkh`, or as another
trusted service with narrowly scoped access to:

- read Woodpecker pipeline state/logs;
- write PR comments in Forgejo.

Do not mount a Forgejo write/comment token into untrusted PR build steps.

PR feedback lanes should run without deployment, signing, cache-push, NATS, or
other high-value secrets. Treat all build output and log text as untrusted input
before copying it into Forgejo comments.

### Reporter trigger model

Preferred trigger: a long-running trusted reporter service consumes
Woodpecker's event stream (`GET /stream/events`) and reacts when a pipeline for
this repository reaches a terminal state such as success, failure, error,
killed, or cancelled. On each terminal event, the reporter fetches authoritative
pipeline metadata and logs from the Woodpecker API, finds the matching PR/head
SHA in Forgejo, reads `check-summary.json` when present, renders a safe
Markdown projection, and updates the sticky PR comment.

Add a small reconciliation timer as a fallback. On a fixed interval, the
reporter should list recent completed pipelines for the dotfiles repository and
ensure the matching sticky PR comments are current. This covers reporter
restarts, dropped event-stream connections, Woodpecker restarts, and any missed
terminal event.

Do not make the primary reporter a normal final pipeline step. Woodpecker can
run status-conditioned steps on success or failure, but such steps execute
inside the pipeline execution model and are adjacent to untrusted PR code. They
also may not run for cancelled pipelines or infrastructure failures. A final
step may be useful later as a non-authoritative nudge, but it must not be the
trusted path that holds the Forgejo comment token.

Do not depend on an undocumented outgoing Woodpecker webhook as the initial
design. Woodpecker's documented extension points cover configuration, registry,
and secret lookup extensions, while the API event stream is the documented
server-side primitive that matches this use case.

### CI summary format

The sticky PR comment should be stable enough for both humans and agents.
The source of truth is the CI artifact:

- `check-summary.json` — structured status, failed checks, local reproduction
  commands, relevant log tails, reporter lookup identity, and full
  log/artifact URLs when available.

The reporter should locate summaries by repository, head SHA, Woodpecker
pipeline number, and workflow/step identity. The PR comment is a trusted
reporter-rendered projection of the artifact, not the only copy of the data.

The PR comment must be updated in place, not appended on every run. The
reporter should render a bounded, escaped Markdown projection from JSON. The
hidden marker and `sha=<head-sha>` let agents find the current summary and
ignore stale summaries after a force-push or new commit. Repeated comments are
noisy for humans and harder for agents to disambiguate.

Decision: `run-checks.sh` must not emit a Markdown summary document. The checks
script emits only structured JSON because a generated Markdown artifact would
duplicate the same information and create an unnecessary Markdown-injection
surface from untrusted build output. Markdown rendering belongs exclusively in
the trusted reporter, which can escape fields, bound output, add the sticky
comment marker, and update Forgejo comments in place.

Recommended initial JSON shape:

```json
{
  "schema": "dotfiles-ci-summary:v1",
  "head": "<sha>",
  "status": "failed",
  "repository": "mutantmell/dotfiles",
  "pipeline_number": "123",
  "pipeline_url": "https://woodpecker.internal/repos/...",
  "workflow": "full-checks",
  "step": "full-checks",
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

### Iteration 1 result

- Added `tea` to the single default dev-machine image output.
- The image sets `TEA_CONFIG_HOME` to `/home/agent/.config/tea`, and the
  entrypoint creates that directory with private permissions.
- `scripts/dev-machine-smoke.sh` now asserts `tea --version` works and the tea
  config directory is private.
- Token injection and normal branch PR creation are still pending, so AGit
  remains the default PR workflow.

### Iteration 2 result

- `scripts/run-checks.sh` accepts `--summary-dir DIR` or
  `CHECK_SUMMARY_DIR=DIR` and writes `check-summary.json`.
- `scripts/agent-preflight.sh` passes the same summary option through to
  `run-checks.sh`.
- The summary schema uses `dotfiles-ci-summary:v1`, records the head SHA,
  reporter lookup fields, overall status, per-check reproduction commands, and
  bounded redacted log tails for failed checks.
- The existing Woodpecker `full-checks` lane writes summaries under
  `ci-summary/` and prints the JSON summary at the end of the step, preserving
  the previous full-check coverage.
- Durable Woodpecker artifact retention and trusted Forgejo comment posting are
  still pending.

### Iteration 3 result

- Added thin dev-machine wrappers around `tea` for the agent-facing CI feedback
  loop:
  - `agent-pr-status [pr-number]` prints PR state, Forgejo CI state, and the
    latest sticky `dotfiles-ci-summary:v1` comment when present.
  - `agent-pr-comments <pr-number>` prints lifecycle and review comments as
    JSON.
  - `agent-pr-comment <pr-number> <message>` posts a concise PR comment through
    `tea`.
- The wrappers fail clearly when `tea` is not configured, so AGit remains the
  operational fallback until API credential injection and branch-push controls
  are validated.
- `scripts/dev-machine-smoke.sh` now asserts the wrappers are available.
- `docs/dev-machine.md` documents the wrappers and their current credential
  limitations.

### Phase 1: Add `tea` to dev-machine

- Add `tea` to the dev-machine tool package.
- Set `TEA_CONFIG_HOME` to an agent-owned location outside the Nix store.
- Add smoke behavior:
  - `tea --version` works and the configured token path has safe
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

- Extend CI check execution so it produces `check-summary.json`. Initial
  implementation writes this from
  `scripts/run-checks.sh --summary-dir`.
- Make failures include:
  - check name;
  - exact local reproduction command;
  - relevant log tail.
- Add later:
  - failing command or phase when the runner can identify it cleanly;
  - full log/artifact URL once Woodpecker artifact lookup is finalized.
- Define durable artifact retention expectations and reporter lookup rules.
- Keep Markdown rendering in the trusted reporter, not in `run-checks.sh`, so
  escaping, stale-comment handling, and PR comment update semantics are owned by
  the component that posts to Forgejo.
- Expand summary redaction as new secret patterns are identified.
- The current repository pipeline emits summaries for the existing full-check
  lane. If CI is later sharded, each shard should emit the same schema with a
  shard/workflow identity for reporter lookup.

### Phase 5: Add trusted Forgejo CI reporter

- Implement a reporter outside untrusted PR build steps.
- The reporter should:
  - consume Woodpecker `GET /stream/events` as the primary trigger;
  - react only to terminal pipeline states for the dotfiles repository;
  - run a timer-based reconciliation pass over recent completed pipelines;
  - identify the PR and head SHA for a completed pipeline;
  - fetch Woodpecker result data/log tails;
  - create or update the sticky `dotfiles-ci-summary:v1` PR comment;
  - avoid duplicate comments on reruns;
  - clearly mark stale summaries when the PR head changes.
- Store reporter credentials through sops-nix or another host-side secret path.
- Keep reporter credentials out of Woodpecker build pods unless the pod is a
  trusted reporter-only job that never checks out untrusted PR code.

### Phase 6: Agent ergonomics

Thin wrapper scaffolding was added early in Iteration 3 so agents have a stable
interface once `tea` credentials are available. The remaining Phase 6 work is to
validate those wrappers against the live credentialed `tea` workflow after Phase
2 and Phase 3 are complete:

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
- Should the event-stream reporter run as a systemd service on `saint-arkh` or
  as a separate internal service?
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
  - remove the instruction not to look for PR API tokens.
- `docs/dev-machine.md`:
  - document where `tea` config lives and how it is cleaned up;
  - document the expected PR/CI feedback loop.
- `scripts/dev-machine-smoke.sh`:
  - assert `tea` presence and token-file permissions.
