# Phase 7 Step 3: Auto image rebuild

## Context

Step 2 established the project-centric `init`/`up`/`down` model. Currently, `up` requires
a pre-existing `image_digest` in state from a manual `cc-sandbox rebuild-image` run. Step 3
makes `up` handle image currency automatically.

## Design

The container image is a pure Nix derivation — its nix store output path is fully determined
by its inputs. If the store path hasn't changed since the last push, the image is current.

New function `ensure_image(config, state)`:
1. `nix build` the image → get store output path
2. Compare against `image_store_path` saved in state
3. If same and `image_digest` is non-empty: skip push, return existing digest
4. If different (or first time): push with skopeo, inspect registry for digest, save
   both `image_store_path` and `image_digest` to state
5. Return the digest

This uses the nix store path as the staleness check rather than inspecting the local
docker-archive for a digest. The store path is a perfect proxy for "has the image changed?"
and avoids any question of whether local archive digests match registry digests.

### Changes

**`cmd_up`**: Replace the digest check + error with a call to `ensure_image()`. The user
never needs to think about images — `up` handles it.

**`rebuild_image`**: Also save `image_store_path` alongside `image_digest` so that a manual
`rebuild-image` followed by `up` doesn't redundantly re-push.

**`ensure_image`**: New function. Extracts the build step (shared with `rebuild_image`) into
a helper `build_image(config)` to avoid duplication.

**State schema**: Add `image_store_path` field (string, default `""`).

**`cmd_rebuild_image`**: Unchanged — always builds and pushes (force override for debugging).

## Files to modify

| File | Action |
|------|--------|
| `packages/cc-sandbox/cc_sandbox.py` | Add `build_image`, `ensure_image`; refactor `rebuild_image`; update `cmd_up` |
| `packages/cc-sandbox/test_cc_sandbox.py` | Tests for `ensure_image`, updated `cmd_up` |
| `llm-notes/wip/cc-sandbox-plan.md` | Update step 3 status |

## Implementation order

1. Extract `build_image(config)` helper from `rebuild_image`
2. Add `ensure_image(config, state)` using `build_image` + conditional push
3. Update `rebuild_image` to use `build_image` and save `image_store_path`
4. Update `cmd_up` to call `ensure_image` instead of checking state
5. Add tests
6. Update plan doc

## Verification

1. `nix build .#cc-sandbox` — package builds
2. `nix build .#checks.x86_64-linux.cc-sandbox` — tests pass
3. On edith:
   - `cc-sandbox up` with no prior `rebuild-image` — builds and pushes automatically
   - `cc-sandbox down && cc-sandbox up` — second `up` skips push (image unchanged)
   - Edit image derivation, `cc-sandbox down && cc-sandbox up` — detects change, re-pushes
