---
name: edith memory constraints
description: edith (Incus container on calvard) has <4GB RAM — nix eval/build can OOM. Don't run concurrent nix builds on edith. calvard has 32GB total.
type: feedback
---

edith (the dev environment Incus container on calvard) has less than 4GB of memory.
Running concurrent `nix build` or `nix build --dry-run` commands can OOM-kill the
session. Prefer running builds on the target host directly (e.g., `nixos-rebuild build`
on remiferia) rather than evaluating locally on edith. Consider bumping edith to 8GB
if doing regular nix development.
