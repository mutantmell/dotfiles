# Documentation and work tracking

Current operator guidance belongs in `docs/`. Proposed and accepted target
contracts must state whether they are implemented. Work is tracked in Forgejo
under `mutantmell-net/dotfiles`; the [migration mapping](../docs/work-tracking.md)
records the completed import. The local draft directory has been removed. Do not recreate plans/wip/done lifecycle trees.

Keep issue scope small, link dependencies, distinguish implementation from live
acceptance, and update operator documentation when work ships. Record completed
implementation history in Git rather than retaining obsolete execution plans.

`open-questions.md` remains the operator's raw scratchpad and is preserved
unchanged in this migration. Its ideas are not approval to deploy. See
[the disposition record](README.md) for which questions became drafts, were
already implemented, or remain unselected.
