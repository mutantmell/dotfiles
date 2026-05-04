# `llm-notes/` Conventions

This directory holds long-form planning notes, specs, guides, and reports.
Plans flow through state directories as work progresses.

## Directory layout

```
llm-notes/
├── CONVENTIONS.md          ← this file
├── feature-roadmap-analysis.md  ← top-level roadmap (not a plan)
├── microvm-inventory.md         ← top-level inventory (not a plan)
│
├── plans/        ← drafted but not yet started
├── wip/          ← work in progress (some phases complete, more remain)
├── blocked/      ← started, currently stuck on an external dependency
├── shelved/      ← deliberately paused; revisit conditions documented
├── done/         ← work complete, kept as historical record
│
├── specs/        ← architecture / target-state specs (not state-tracked)
├── guides/       ← runbooks and operational guides (not state-tracked)
└── reports/      ← analyses, surveys, decision write-ups (not state-tracked)
```

Only `plans/`, `wip/`, `blocked/`, `shelved/`, and `done/` participate in
the plan lifecycle. Files in `specs/`, `guides/`, and `reports/` are
reference material that doesn't move.

## State directories

### `plans/` — drafted, not started

A plan goes here when it has been written down but no code has been merged
toward it. The repo state shows none of the plan's deliverables yet.

**Naming convention:** descriptive kebab-case ending in `-plan.md` is
typical but not required for short specs. Match what's already in the
directory.

### `wip/` — in progress

A plan is in `wip/` when at least one phase has been implemented and
merged, but later phases remain. The plan should mark phase status
inline (`### Phase N — COMPLETE` / `### Phase N — NOT STARTED`) so a
reader can tell what's left without diffing against the code.

If you abandon the plan partway, move it to `done/` with a clear
"Status: Abandoned" header explaining why and what was kept; or to
`shelved/` if you intend to resume.

### `blocked/` — started, stuck on external dependency

Use this when work has begun but cannot continue until something
outside this repo changes — upstream bug fix, hardware arrival, a
decision in another project, etc.

The plan **must** include a top-level `## Blocked on` section
naming the specific dependency and the condition under which it
becomes unblocked. Without that, use `wip/` or `shelved/` instead.

### `shelved/` — deliberately paused

Use this when work is intentionally deferred — not blocked on anything
external, just a conscious decision to do it later.

The plan **must** include a top-level `## Status` line that says
"Shelved" and a short note on what would cause us to pick it back up
(a maturity threshold, dependent feature shipping, etc.).

`shelved/` differs from `blocked/`: blocked plans wait on something
specific to change; shelved plans are paused by choice and have no
external trigger.

### `done/` — complete

Plans land here when their deliverables are merged and the system
reflects them. Include a brief status note at the top (date, what was
actually shipped vs. plan deviations). `done/` is also where abandoned
plans live, with an explicit "Won't Do" / "Abandoned" header.

A plan in `done/` should still be useful as a historical record. If it
references hostnames, IP ranges, or services that have since been
renamed/removed, prefer to either:

- **Keep it but add a note** at the top mapping old names to new, when
  the plan captures a meaningful design decision; or
- **Delete it** if the plan was superseded and nothing in it is
  still load-bearing for understanding the current system.

The bar for "delete" is: would a reader looking at this plan today
be more confused than informed? If yes, delete. The code and git
history are the source of truth — `done/` is supplementary.

## Lifecycle

```
        ┌──── planned ────┐
        ▼                 │
   plans/                 │
     │                    │
     │ start work         │ revisit
     ▼                    │
   wip/ ──── stuck ───► blocked/
     │                    │
     │ pause              │ unblock
     ▼                    ▼
   shelved/           wip/ (resume)
     │
     ▼
   done/   ◄── ship from any state
```

Plans can move backward too: a `wip/` plan that stalls indefinitely
can move to `shelved/`; a `done/` plan that turns out to need more
work can be replaced by a new `wip/` plan that supersedes it (don't
re-open the old one — write a new plan and link to the predecessor).

## When to write a new plan vs. update an existing one

- **New plan** when the design changed substantively, or when scope
  expanded beyond the original plan's boundaries. Reference the
  predecessor with `Replaces: <path>` or `Supersedes: <path>` in the
  header. Move the predecessor to `done/` (with a postscript pointing
  forward) or delete it if it's been fully subsumed.
- **Update in place** for incremental refinement, status changes, or
  added phases on the same trajectory.

## Other directories

- **`specs/`** — target-state architecture documents. Specs describe
  *what we want*; plans describe *how we'll get there*. Specs change
  rarely; they don't have a state lifecycle.
- **`guides/`** — operator-facing runbooks and how-tos for living
  systems. Update as the system evolves.
- **`reports/`** — analyses and surveys (e.g. friend-access threat
  models, dynamic-network research). One-shot deliverables, not
  state-tracked.

## Rules of thumb

- Status is in the directory, not just in the document. If the
  directory and the document disagree, the directory wins — fix
  the document.
- Don't leave a plan in `wip/` after you've stopped working on it.
  Move it to the right place (`done/`, `blocked/`, `shelved/`).
- When deleting from `done/`, prefer it over keeping a doc that
  actively misleads (old hostnames, dead architectures, references
  to services that no longer exist).
- Cross-link aggressively: when a plan supersedes another, link to
  the predecessor; when a plan depends on another, say so up top.
