# Transfer dotfiles to mutantmell-net

Preparation recorded on 2026-10-25. The operator must perform the ownership
transfer; this checklist does not authorize it. Use Forgejo's ownership transfer
on the existing repository, rather than importing a replacement repository.
The purpose is to grant agents Issues write through an organization team while
keeping upstream Code read-only.

## Pre-transfer inventory

Read-only observations using the injected `cc` credentials:

| Item                   | Observed state                                                                                                                                                      |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Upstream               | `mutantmell/dotfiles`, Forgejo repository ID **1**, public, default branch `main`                                                                                   |
| Destination            | `mutantmell-net/dotfiles` (not yet transferred)                                                                                                                     |
| Local baseline         | `main` at `a9bc530c54b2f07621e220168c46e4b4d9da2e5e` before preparation                                                                                             |
| Bot fork               | `cc/dotfiles`, repository ID **10**, parent repository ID **1**, default branch `main`                                                                              |
| Open PRs               | **#180** `docs/flint2-luci-setup`; **#176** `docs/krea2-refinement-workflows`; **#175** `docs/bt8-recovery-runbook`                                                 |
| PR relationships       | All three target upstream `main` from branches in `cc/dotfiles`; the preparation PR will add another                                                                |
| Account access         | Upstream `pull: true`, `push: false`, `admin: false`                                                                                                                |
| Features               | Issues and projects enabled; operator-created status labels already exist                                                                                           |
| Git remotes            | `origin` fetches `https://forgejo.internal/mutantmell/dotfiles.git`, push URL `no_push_to_origin`; `fork` fetches/pushes `https://forgejo.internal/cc/dotfiles.git` |
| Intended GitHub mirror | Personal `mutantmell/dotfiles`; no GitHub ownership change required                                                                                                 |

Webhook and push-mirror API inspection was **denied**: both require repository
admin access. Their destinations, enabled state, last successful delivery/sync,
and credentials have **not** been verified. The repository's `mirror: false`
field describes pull-mirror mode; it does not establish whether push mirrors exist.
The operator must inspect these settings before transfer. Do not copy tokens,
webhook secrets, or credential-bearing mirror URLs into this document.

Woodpecker API inspection with the injected token failed with network unreachable; live repository
mapping and recent pipeline state remain unverified. Source configuration allows
organization `mutantmell-net` and repository owner `mutantmell` in
`hosts/erebonia/microvm/guests/saint-arkh/modules/woodpecker.nix`.
The helper default `DOTFILES_WOODPECKER_REPO_ID=1` is a **Woodpecker ID**, not proof
of its live mapping to Forgejo ID 1. CI configuration is `.woodpecker/full-checks.yml`;
it handles push, pull-request, and manual events with runner label `nixos-kvm`.

## Before transfer: operator checks

- Verify a restorable Forgejo database/metadata backup, attachments, and Git data.
  Git mirroring alone does not back up issues, PRs, labels, projects, or hooks.
- Confirm destination ownership and that `dotfiles` does not already exist there.
- Review all organization teams, especially default/all-repository teams, to
  ensure `cc` will not inherit Code write permission.
- Prepare a repository-scoped agent team: Code Read, Issues Write, Pull Requests
  Read. Confirm `cc` can still create fork PRs with these effective permissions.
- Record webhook type, enabled state, event selection, and last delivery; inspect
  Woodpecker's current repository ID, configuration path, activation, and secrets.
- Record the GitHub push mirror destination and last successful sync. Keep its
  target at `mutantmell/dotfiles`; keep secrets in operator storage.
- Check repository-restricted token access and branch protection. Plan to verify
  these after transfer rather than assuming redirects preserve authorization.
- Review/merge the preparation PR through the normal fork workflow before transfer,
  or explicitly account for its open state in the post-transfer PR checks.

## After operator transfer

1. Verify repository ID **1** is now `mutantmell-net/dotfiles`, the old URL redirects,
   issues (including #188), labels, project, PRs, and attachments are intact.
2. Verify fork ID **10** still has parent ID **1** and existing PR heads are intact.
3. Update each checkout's upstream fetch URL and retain the push prohibition:

   ```bash
   git remote set-url origin https://forgejo.internal/mutantmell-net/dotfiles.git
   git remote set-url --push origin no_push_to_origin
   ```

4. Update operator checkout/dev-machine launch URLs, bookmarks, and credentials
   scoped to the old repository. Keep `fork` pointing at `cc/dotfiles`.
5. Verify team permissions and `write:issue` token scope by assigning/removing
   labels and updating an operator-created test issue, then restore its state.
6. Verify Woodpecker sees the new owner/path, its webhook deliveries succeed,
   secrets/configuration remain available, and an existing or new fork PR runs CI
   and reports checks. If the Woodpecker repository ID changes, set
   `DOTFILES_WOODPECKER_REPO_ID` accordingly. Reconcile existing activation first;
   do not blindly delete/recreate it and lose history or configuration.
7. Verify a GitHub push-mirror sync succeeds to the unchanged personal repository.
8. Rebuild/publish dev images and refresh containers through the normal operator
   process when ready to distribute the helper changes. Until then, existing
   image helpers still hardcode the old Forgejo owner; do not rely on redirects.
9. Verify issue/PR helpers against the new origin, then mark this migration complete
   and remove transitional wording from agent guidance.

## Helper transition

Updated PR and PR-based CI helpers derive `OWNER/REPO` from the `origin` **fetch**
URL, so the preparation PR works against the current owner. They accept HTTPS,
SSH URL, and SCP-style origins on `forgejo.internal`. They reject other hosts
unless `DOTFILES_FORGEJO_REPO=OWNER/REPO` is explicitly supplied.
`agent-pr-create --repo OWNER/REPO` takes precedence over discovery and the
environment override. PR status also explicitly uses upstream rather than relying
on Tea choosing between `origin` and `fork`.

The image registry's `mutantmell` namespace, the separate `mutantmell/agents`
profile repository, historical notes, and GitHub links remain unchanged.
