# Agent CI Read-Only Woodpecker Plan

> **Status:** Planning.
>
> This plan supersedes the sticky-comment-first direction in
> `llm-notes/done/agent-ci-feedback-loop-plan.md` for the default agent CI
> feedback loop. The hardened trusted-reporter design remains a possible later
> option, but the default path should use standard Forgejo and Woodpecker
> surfaces first.

## Goal

Give coding agents enough CI visibility to iterate on pull requests without
granting them write access to CI, repository settings, deployment credentials,
or Forgejo comment tokens.

The desired default loop is:

1. The agent runs quick local checks.
2. The agent pushes a branch to its own Forgejo fork and opens or updates a PR
   against the upstream dotfiles repo.
3. Forgejo triggers Woodpecker.
4. Woodpecker reports commit status back to Forgejo.
5. Forgejo branch protection gates merges on the Woodpecker status.
6. The agent reads PR/CI state through Forgejo and reads detailed CI logs from
   Woodpecker with read-only access.
7. The agent reproduces failing checks locally with repo-local commands.

## Non-Goals

- Copying every CI failure summary into Forgejo comments by default.
- Giving agents Woodpecker admin, project settings, secret, registry, deploy,
  or restart permissions.
- Giving untrusted PR build steps a Forgejo comment token.
- Giving the agent identity direct push access to the upstream dotfiles repo.
- Replacing Woodpecker with Forgejo Actions.
- Building a bespoke Woodpecker client before the standard UI/API surfaces have
  been proven insufficient.

## Current State

- Woodpecker is configured for Forgejo OAuth on `woodpecker.internal`.
- The server config currently has:
  - `WOODPECKER_FORGEJO = "true"`
  - `WOODPECKER_FORGEJO_URL = "https://forgejo.internal"`
  - `WOODPECKER_OPEN = "true"`
  - `WOODPECKER_ORGS = "mutantmell-net"`
  - `WOODPECKER_REPO_OWNERS = "mutantmell"`
  - `WOODPECKER_ADMIN = "mutantmell"`
- `.woodpecker/full-checks.yml` runs:

  ```bash
  ./scripts/run-checks.sh --summary-dir ci-summary
  ```

  and prints `ci-summary/check-summary.json` into the Woodpecker log.
- `run-checks.sh --summary-dir` emits a useful repo-local JSON summary with:
  - schema `dotfiles-ci-summary:v1`;
  - head SHA and pipeline lookup fields;
  - check names and status;
  - exact local reproduction commands;
  - bounded, redacted failed-check log tails.
- `tea` and thin PR wrappers exist in the dev-machine image, but Forgejo API
  token injection and the fork-and-pull PR flow are not yet validated.
- `llm-notes/done/agent-ci-feedback-loop-plan.md` explored a trusted sticky PR
  comment reporter. That path is safer when agents cannot read Woodpecker, but
  it adds custom machinery that is unnecessary if agents can have read-only
  Woodpecker access.
- Repo-side sticky-comment scaffolding has been removed from the default
  dev-machine wrapper layer:
  - `packages/dev-machine-tools.nix`: `agent-pr-status` no longer fetches PR
    comments looking for `dotfiles-ci-summary:v1`.
  - `docs/dev-machine.md`: `agent-pr-status` is documented as showing PR state
    and Forgejo CI state, with detailed failure information coming from
    Woodpecker logs.

## Design

### Source of truth for merge gates

Use Woodpecker's Forgejo commit status as the merge gate.

Configure Forgejo branch protection for `main` to require the relevant
Woodpecker status context for PR heads before merge. Keep human review required
separately.

Expected status context:

- The likely required Forgejo status context is
  `ci/woodpecker/pr/full-checks`.
- This is inferred from the local workflow file name
  `.woodpecker/full-checks.yml` and Woodpecker's default status context
  formatting. The live Forgejo status still needs to be checked before branch
  protection is finalized.
- The status target URL is expected to point at the matching Woodpecker
  pipeline page, but that also needs live validation on a real PR.

### Agent visibility

Give the agent identity read-only visibility into Woodpecker.

The preferred identity is the same Forgejo SSO user used by the agent, for
example `cc`, with repository-level read access to `mutantmell/dotfiles`.

Expected permission model:

- Forgejo `Read` permission should allow viewing/cloning the repository and
  viewing PRs, without direct push, merge, branch protection, or repository
  settings access.
- Woodpecker permissions are linked to Forgejo permissions.
- A Woodpecker user with access to a project can see builds, logs, and
  artifacts.
- Woodpecker project settings, secrets, and registries remain owner/admin-only.

### Agent PR authorship

Use Forgejo's normal fork-and-pull model for agent-authored changes.

The preferred write shape is:

- upstream repo: `mutantmell/dotfiles`, or `mutantmell-net/dotfiles` if the
  repo is moved into the org later;
- agent fork: `cc/dotfiles`;
- agent push scope: write to `cc/dotfiles` only;
- PR target: upstream `main`;
- merge authority: humans only, through protected branch rules.

This keeps the agent identity out of the upstream branch namespace while still
using standard Forgejo PRs, status checks, and review flows. It also matches the
organization model: membership in `mutantmell-net` gates Woodpecker login, while
repository permissions separately grant `cc` read access to the upstream repo
and write access only to its fork.

AGit remains an acceptable interim submission path until the fork remote,
scoped push credential, and `tea`/Forgejo API PR creation flow are validated in
the dev-machine. Once the fork-and-pull path is validated, make it the default
agent PR workflow and keep AGit only as a fallback repair path.

Expected Woodpecker visibility:

- Use Woodpecker `Internal` visibility for the dotfiles project so the
  authenticated `cc` user can see builds, logs, and artifacts.
- Do not rely on Woodpecker `Private` visibility for this workflow. Upstream
  docs describe `Private` as visible only to repository owners, which would
  exclude a read-only Forgejo collaborator.
- Before enabling or relying on `Internal`, restrict who can log in to
  Woodpecker.

The current server keeps `WOODPECKER_OPEN = "true"` and sets
`WOODPECKER_ORGS = "mutantmell-net"`. `mutantmell` is the Forgejo user account
that owns the repo, so it remains in `WOODPECKER_REPO_OWNERS`;
`mutantmell-net` is the domain/homelab Forgejo organization and doubles as the
Woodpecker login allowlist. This keeps Forgejo SSO registration available for
approved organization members while avoiding arbitrary Forgejo account access
when Woodpecker projects use `Internal` visibility. Live validation still needs
to confirm the agent user is in the approved Forgejo organization. Because this
is a login/registration restriction, also audit existing Woodpecker users before
relying on `Internal` visibility; do not assume the org filter evicts users who
already registered.

### Log and artifact exposure

Read-only Woodpecker access is still broad CI data access.

Treat all logs and artifacts for visible Woodpecker projects as readable by the
agent identity. CI jobs should not print secrets, tokens, private keys,
deployment credentials, or unnecessary environment dumps. Keep PR feedback lanes
free of deployment, signing, cache-push, registry-write, and other high-value
secrets unless those lanes are separately restricted from agent-visible logs.

The current full-check lane is a good fit for this model because it runs
repo-local checks and prints bounded, redacted `check-summary.json` output.

### CI detail format

Keep `check-summary.json`.

This is bespoke, but it is the right primary format for this repository:

- Nix flake checks are build targets, not ordinary unit-test cases.
- JUnit XML and TAP are awkward for "failed Nix check plus exact reproduction
  command plus bounded log tail".
- SARIF is for static-analysis findings and is not a good fit for Nix build
  failures.
- Nix build logs and derivation metadata alone do not provide a compact,
  machine-readable list of failed checks and local reproduction commands.

The Woodpecker log should continue to print the JSON summary. If artifacts are
easy to retain later, also persist `ci-summary/check-summary.json` as a
Woodpecker artifact, but do not add object storage only for this feature.

### Agent workflow

The agent should use standard surfaces:

```bash
agent-pr-status [pr-number]
```

Expected output:

- PR state;
- mergeability;
- Forgejo-visible CI state;
- Woodpecker status target URL, if Forgejo exposes it through `tea` or the
  commit-status API.

When CI fails:

1. Open the Woodpecker status target URL or query the Woodpecker API with the
   read-only agent identity.
2. Find the printed `===== check-summary.json =====` block, or download the
   artifact if artifact retention is enabled.
3. Use the failed check's `reproduce` command locally, for example:

   ```bash
   ./scripts/run-checks.sh network-registry
   ```

4. Push a fix and wait for the Forgejo/Woodpecker status to update.

### What becomes optional

The sticky PR comment path is optional hardened mode, not the default.

Keep it only if one of these turns out to be true:

- agents cannot be given read-only Woodpecker access;
- Woodpecker logs are not reachable from the dev-machine;
- Woodpecker status target URLs are not visible through Forgejo/`tea`;
- copying bounded CI summaries into Forgejo comments is operationally more
  reliable than reading Woodpecker logs.

If the read-only Woodpecker path works, keep the reverted sticky-comment poster
scaffolding out of the default agent surface.

## Implementation Plan

### Phase 1: Validate access model

- Create or identify the agent Forgejo user, likely `cc`.
- Create or identify the Forgejo `mutantmell-net` organization used as the
  domain/homelab org and Woodpecker login allowlist.
- Add or confirm the agent user in the Forgejo `mutantmell-net` organization so
  it can pass the Woodpecker `WOODPECKER_ORGS = "mutantmell-net"` login
  restriction.
- Grant that user read-only access to `mutantmell/dotfiles`.
- Create or confirm the `cc/dotfiles` fork and grant the dev-machine's scoped
  `cc` push credential write access to that fork, not to the upstream repo.
- Audit existing Woodpecker users and remove any account that should not retain
  access before treating `Internal` project visibility as safe.
- Log in to Woodpecker through Forgejo SSO as that user.
- Verify the user can:
  - see the dotfiles Woodpecker project;
  - see recent pipelines;
  - open step logs;
  - read the printed `check-summary.json`;
  - use the Woodpecker API for read-only pipeline/log access if API use is
    desired.
- Verify the user cannot:
  - change Woodpecker project settings;
  - read Woodpecker secrets or registries;
  - restart, cancel, approve, or deploy pipelines if those actions are outside
    the intended read-only scope;
  - push directly to protected Forgejo branches;
  - merge PRs or edit branch protection.

- Configure dotfiles project visibility as `Internal`, unless live testing shows
  read-only Forgejo collaborators can see it under `Private`.
- Before relying on `Internal`, restrict Woodpecker login scope so CI logs are
  visible only to approved Forgejo users.

### Phase 2: Validate merge gate

- Open or reuse a test PR, preferably from `cc/dotfiles:<branch>` into the
  upstream `main` branch.
- Confirm Woodpecker runs on the PR event.
- Record the exact Forgejo status context name. Expected:
  `ci/woodpecker/pr/full-checks`.
- Confirm the status target URL opens the matching Woodpecker pipeline page.
- Configure branch protection on `main` to require that status.
- Confirm a failing Woodpecker run blocks merge.
- Confirm a passing Woodpecker run satisfies the required status but still
  requires human review.

### Phase 3: Improve agent status ergonomics

- Update `agent-pr-status` only if needed to show the Woodpecker target URL.
- Prefer Forgejo's commit status API through `tea api` over a custom Woodpecker
  client when the target URL is available from Forgejo.
- Remove sticky-comment lookup from the default `agent-pr-status` output once
  this read-only Woodpecker path is accepted. Sticky summaries can remain a
  separate hardened-mode feature if needed later.
- Keep Woodpecker API access read-only and optional.
- Do not add posting/comment wrappers for the default path.

### Phase 4: Simplify existing scaffolding

Repo-side cleanup can happen independently of live validation:

- Keep `llm-notes/done/agent-ci-feedback-loop-plan.md` archived as the
  superseded trusted-reporter design.
- Update `docs/dev-machine.md` to describe the default read-only Woodpecker
  workflow.
- Remove sticky-comment lookup from `agent-pr-status` in
  `packages/dev-machine-tools.nix`. The default status helper should print PR
  state, Forgejo CI state, and the Woodpecker status target URL when available.
- Update `docs/dev-machine.md` so `agent-pr-status` is no longer described as
  showing a sticky CI summary.
- Keep sticky-comment poster/renderer scaffolding out of the default
  agent-facing wrappers.
- Keep the reverted Markdown renderer out of the default path unless the
  hardened sticky-comment mode is deliberately revived later.

## Validation Checklist

- `cc` has Forgejo read-only access to dotfiles.
- `cc` can push branches to `cc/dotfiles` and open PRs against the upstream
  repo, but cannot push directly to upstream branches.
- Woodpecker login is restricted before dotfiles project visibility is set to
  or treated as `Internal`.
- Existing Woodpecker users have been audited, and any users outside the
  intended `mutantmell-net` allowlist have been removed or explicitly accepted.
- `cc` can read Woodpecker logs for dotfiles pipelines.
- `cc` cannot access Woodpecker settings, secrets, registries, deploy controls,
  or protected Forgejo branch controls.
- Woodpecker status appears on Forgejo PRs with a target URL.
- Forgejo branch protection requires the Woodpecker status before merge.
  Expected context: `ci/woodpecker/pr/full-checks`.
- Failed CI logs include `check-summary.json`.
- An agent can use the summary's `reproduce` command locally.

## Answered Questions And Remaining Validation

- Woodpecker project visibility: use `Internal` for the default path unless
  live testing contradicts upstream docs about `Private` owner-only visibility.
- Woodpecker login restriction: `WOODPECKER_ORGS = "mutantmell-net"` is
  configured; live validation still needs to confirm that Forgejo organization
  exists, includes the agent user, and allows the user to log in.
- Status context: likely `ci/woodpecker/pr/full-checks`; verify from a real PR
  status before configuring branch protection.
- Forgejo branch protection: expected to support requiring the Woodpecker
  status; validate in the live Forgejo UI/API.
- Status target URL: expected to point to Woodpecker; validate from a real PR.
- `tea pr --fields ci`: unknown whether it exposes enough target URL detail.
  If not, call Forgejo commit statuses through `tea api`.
- Woodpecker API access: generally supports read-only pipeline/log reads, but
  the agent token/login flow needs live validation. Browser/log URL access may
  be enough.
- Fork-and-pull PR flow: preferred target model; validate `cc/dotfiles` fork
  creation, scoped push credentials, and `tea`/Forgejo API PR creation before
  replacing AGit as the default operational submission path.
- Artifact retention: not required initially. Printing `check-summary.json` in
  logs is sufficient unless logs prove hard for agents to consume.

## Recommended Near-Term Chunk

Do not add more sticky-comment reporter code.

Next, validate the live service behavior:

1. Deploy the Woodpecker login-scope change.
2. Validate `cc` read-only access to the dotfiles Woodpecker project, logs, and
   `check-summary.json`.
3. Validate `cc/dotfiles` fork push and PR creation into upstream `main`.
4. Validate the live Forgejo status context and target URL.
5. Configure branch protection for the Woodpecker status.
6. Confirm the default agent workflow is fork-and-pull PRs, Forgejo status, and
   read-only Woodpecker logs, while sticky PR comments remain optional
   hardened-mode scaffolding only.
