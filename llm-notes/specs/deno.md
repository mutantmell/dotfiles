# Scripting Strategy: TypeScript + Deno + Dax

## Executive Summary

All operational scripts in this flake are written in TypeScript, executed by
Deno, and use the `dax` library for shell-like process orchestration. This
replaces a previous mix of bash and Python scripts.

Dependencies are managed by vendoring: all third-party code lives in a
`vendor/` directory committed to this repository. Scripts are wrapped as
NixOS derivations using a `runCommand` assembly pattern that combines static
TypeScript source with any Nix-generated configuration modules, producing
proper executables on `$PATH` backed by a pinned Deno version from nixpkgs.

The Deno version is pinned to whatever nixpkgs revision this flake tracks.
No external flake inputs or third-party packaging infrastructure are required.

---

## Justification

### The problems with the previous approach

The prior mixture of bash and Python had three concrete failure modes:

**Bash data structures are inadequate for complex scripts.** Bash arrays have
arcane syntax, inconsistent behaviour across versions, no support for nested
structures, and no way to describe the shape of data. Scripts that manipulate
structured data in bash are both difficult to write correctly and difficult to
audit. This is not a matter of familiarity — it is a fundamental limitation of
the language.

**Mixed languages impose maintenance overhead.** Switching between bash
semantics and Python semantics across different scripts means two sets of
idioms for error handling, process spawning, and data manipulation. This
cognitive overhead compounds when reading or modifying scripts under time
pressure.

**LLM-assisted maintenance is unreliable for bash.** Bash scripts that use
arrays and complex control flow are a known failure mode for LLM code
generation — the output looks plausible but is often subtly wrong in ways
requiring expert review to catch (unquoted variables, array expansion bugs,
silent error swallowing). TypeScript with strong typing shifts error detection
to the type system and makes LLM-generated code easier to audit. Biasing
toward cleaner, more explicit code is the right strategy in a world where LLM
assistance is part of the maintenance workflow.

### Why TypeScript + Deno + Dax

**Dax solves the core problem.** Dax provides bash-like process orchestration
(the `$\`command\``tagged template syntax) without delegating to the system
shell. Unlike zx (the Google library that inspired it), dax uses`deno_task_shell`— a purpose-built cross-platform shell parser — which means
shell builtins like`rm`and`cd`behave consistently regardless of what is on`$PATH`. This eliminates an entire class of environmental brittleness.

**Deno provides the right runtime properties for scripting.** It runs
TypeScript natively with no build step, has no `node_modules` or `package.json`
overhead for single-file scripts, and its permission model (`--allow-read`,
`--allow-write`, etc.) makes the capabilities of each script explicit. The
single binary model integrates cleanly with NixOS: one package in the flake,
pinned, always available.

**TypeScript provides real data structures.** Arrays of objects, maps,
structured types — all with editor assistance and type checking. The problems
that motivated this migration (complex bash array manipulation that is hard to
audit or extend) do not exist in TypeScript.

**Language consolidation.** A single scripting language means shared idioms,
shared utilities, and a single mental model across all operational scripts.

---

## Alternatives Considered

### Stay with bash + Python

Rejected. The data structure limitations of bash are the direct motivation for
this migration. Python is a capable language but adds a second runtime and a
second set of idioms without providing the process orchestration ergonomics
that make dax compelling. The Python `subprocess` story is notably worse than
dax's `$\`...\`` syntax.

### zx (Google's library) on Node.js

zx is the library that inspired dax and is better supported by the Node.js
ecosystem, which has mature nixpkgs packaging infrastructure
(`buildNpmPackage`, `importNpmLock`). However, zx delegates process spawning
to the system shell via Node's `child_process.spawn`, making it dependent on
whichever shell is on `$PATH` and vulnerable to the same class of
environmental brittleness as bash. Dax's use of `deno_task_shell` is a
meaningful architectural improvement, not just an API difference.

### Native Deno packaging via nixpkgs (`fetchDenoDeps` / `buildDenoPackage`)

A native `buildDenoPackage` function for nixpkgs exists as a pull request
(#453904 / #419255) but was abandoned by its author in February 2026 after
nine months of review delays. The technical work is sound; the blocker is
social — finding reviewers with overlapping expertise in nixpkgs
build-support infrastructure and Deno's packaging model.

Even if merged, Deno's lockfile format has gone through five major versions
since 2022 (v2 through v5), with each version bump causing breakage for
downstream tooling including Supabase, Deno Deploy, and CI environments that
lag behind the CLI. The format is not covered by Deno's stability guarantees
and has been changed to deliver performance improvements. Any native nixpkgs
packaging solution would require ongoing maintenance on a roughly
per-major-release cadence.

### `deno2nix` (third-party flake overlay)

The author of the abandoned nixpkgs PR published the same code as a standalone
flake. It solves the packaging problem but has had no activity since its
initial creation, has no CI, and depends on a single maintainer's continued
interest. The lockfile instability risk applies equally here.

### Vendoring with Nushell

Nushell is async-native, has structured data as a first-class concept, and has
reasonable nixpkgs support. Rejected because it is its own language rather
than TypeScript, providing no path to language consolidation with any other
TypeScript code in the environment, and lacking the shell orchestration
ergonomics of dax.

---

## Strategy

### Dependency management: vendor everything

All third-party dependencies are vendored into the `scripts/vendor/` directory
using `deno vendor` and committed to this repository. No network access is
required at build time. Dependencies are updated deliberately by re-running
`deno vendor` and reviewing the diff before committing.

This is not equivalent to the full Nix approach (content-addressed hashing of
all inputs), but it is the pragmatic single-maintainer solution available
today. The vendored code and its licenses are fully visible in the git
history, making supply chain changes auditable. When native nixpkgs Deno
packaging matures, migration from vendoring to `fetchDenoDeps` is
straightforward.

**License compliance:** all vendored dependencies must be MIT or equivalently
permissive. The `vendor/` directory preserves upstream license files. A note
in the top-level `LICENSE` file acknowledges that `scripts/vendor/` contains
third-party code under their respective licenses.

**Keep the dependency footprint small.** Scripts should rely on `dax` and
`@std` (the Deno standard library, also MIT) and avoid npm dependencies.
npm packages can grow vendor directories dramatically and introduce more
complex license situations. Almost everything needed for system scripting is
achievable with dax and `@std`.

### Nix integration: `runCommand` assembly

Scripts that need Nix-generated content (configuration values derived from the
NixOS module system) receive it via one of two patterns:

**For data**: configuration is written to `/etc` via `environment.etc` as
JSON, which the script reads at runtime. This is the same pattern NixOS
services use for configuration injection and requires no special build-time
assembly.

**For TypeScript modules**: when generated content needs to be importable
(typed constants, generated type definitions), a `runCommand` derivation
assembles a directory containing both the static script source and the
generated module. The wrapper script points Deno at this assembled directory.

```nix
let
  generatedConfig = pkgs.writeText "config.ts" ''
    export const hostname = "${config.networking.hostName}";
  '';
  scriptDir = pkgs.runCommand "my-script-src" {} ''
    mkdir $out
    cp -r ${./scripts}/. $out/
    cp ${generatedConfig} $out/config.ts
  '';
in pkgs.writeShellScriptBin "my-script" ''
  exec ${pkgs.deno}/bin/deno run \
    --frozen --allow-read --allow-run \
    ${scriptDir}/main.ts "$@"
''
```

### Script conventions

- Each script declares its required permissions explicitly and minimally.
  `--allow-all` is not acceptable for committed scripts.
- Scripts that can be run safely as a dry run should support a `--dry-run`
  flag.
- Error handling uses dax's default behaviour (non-zero exit throws) and does
  not use `.noThrow()` without a comment explaining why.
- Process orchestration that can be parallelised uses `Promise.all()`.
- Data passed between script stages uses typed interfaces, not untyped
  strings.

### Migration path

Existing bash and Python scripts are migrated opportunistically — when a
script needs to be modified for another reason, that is the moment to rewrite
it. Scripts that are stable and unlikely to change are left in place until
they need attention. There is no deadline for completing the migration.

When the nixpkgs `fetchDenoDeps` / `buildDenoPackage` situation resolves,
vendoring can be replaced with proper content-addressed dependency fetching.
The script source and wrapper patterns do not change; only the dependency
management mechanism changes.
