# deployd: per-container runtime selection (kata vs runc)

## Goal

Let cc-sandbox deploy with the plain runc runtime so it gets bare-metal KVM
for nested VMs without going through kata. Keep kata installable and
selectable for other deployd workloads (isolated builds, future
integrations) — the host config decides which runtimes are permitted, and
clients pick per-deploy.

## Background

Current state (`modules/deployd/default.nix:272`): runtime is a single
host-wide knob (`kata.enable` → boolean). The selected class becomes
`DEPLOYD_RUNTIME_CLASS` env, which deployd-helper passes to every container.
Clients have no say.

cc-sandbox needs nested KVM. The kata path was the only available option,
and `pkgs.mmell.kata-kernel-nested` was an attempt to make kata's guest
kernel host-KVM-capable. That kernel currently hangs on container launch.
Since runc gives containers direct access to the host's `/dev/kvm`, runc is
the simpler answer for cc-sandbox — and removes the kata-kernel-nested
maintenance burden entirely.

We still want kata available for workloads where strong isolation matters
more than nested-virt performance.

## Validation policy

For now: trust the host config. If a host's `runtimes.allowed` includes
`runc`, any authenticated client may request it. Future work (out of scope):
OAuth-group gating once we have multiple consumers with differing trust
levels.

## Changes

### 1. Protocol — add per-container runtime field

`packages/deployd-helper/src/protocol.rs`:

- Add `Runtime` enum: `Kata | Runc`. Use `#[serde(rename_all = "lowercase")]`.
- Add to `ContainerDefinition`:
  ```rust
  #[serde(default)]
  pub runtime: Option<Runtime>,
  ```
  `None` → fall through to host default.

`packages/deployd-api/src/helper.rs`: mirror the same enum and field on the
API-side `ContainerDefinition`. The API forwards verbatim — no logic
changes in `routes.rs`.

### 2. Helper config — runtime allowlist + default

`packages/deployd-helper/src/config.rs`:

- Replace `runtime_class: String` with:
  ```rust
  pub allowed_runtimes: Vec<Runtime>,   // parsed from comma-separated env
  pub default_runtime: Runtime,
  ```
- New env vars (both required — module always sets them, no helper-side
  fallback to keep the source of truth in one place):
  - `DEPLOYD_ALLOWED_RUNTIMES` (e.g. `"kata,runc"`)
  - `DEPLOYD_DEFAULT_RUNTIME` (e.g. `"kata"`)
- Keep helper-side mapping `Runtime → containerd runtime class string`
  (`Kata → "io.containerd.kata.v2"`, `Runc → "io.containerd.runc.v2"`).

### 3. Validation

`packages/deployd-helper/src/validation.rs`:

- Add `validate_runtime(requested: Option<Runtime>, allowed: &[Runtime])`.
  - `None` is always OK (will resolve to default at execute time).
  - `Some(x)` must be in `allowed`.
- Wire into `validate_container`.
- Tests: requested-and-allowed, requested-but-not-allowed, none-OK.

### 4. Executor

`packages/deployd-helper/src/executor.rs`:

- Resolve runtime: `def.runtime.unwrap_or(config.default_runtime)`.
- Map to containerd runtime class string and pass to `generate_unit`.
- `unit.rs` already takes runtime class as a `&str` parameter — no change.
- Audit: include the resolved runtime in the audit log entry (extend
  `audit::log_command` or stuff into the message).

### 5. Module — runtimes option

`modules/deployd/default.nix`:

- Replace `kata.enable` (and the existing `kata.kernelPackage`) with a
  single `runtimes` namespace:
  ```nix
  runtimes = {
    allowed = mkOption {
      type = types.listOf (types.enum ["kata" "runc"]);
      default = ["runc"];
      description = "Container runtimes permitted on this host. Clients may request any of these per-deploy.";
    };
    default = mkOption {
      type = types.enum ["kata" "runc"];
      default = builtins.head cfg.runtimes.allowed;
      defaultText = lib.literalExpression "builtins.head config.deployd.runtimes.allowed";
      description = "Runtime used when a deploy request omits the runtime field.";
    };
    kata.kernelPackage = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "Kernel package for Kata guest VMs. When null, uses upstream Kata's bundled kernel via the unmodified configuration-qemu.toml.";
    };
  };
  ```
  Defaulting `runtimes.default` to `head allowed` keeps the two options in
  sync — a host that sets only `allowed = ["kata"]` doesn't have to
  remember to set `default` too.
- Assertion: `runtimes.default` must be in `runtimes.allowed` (defends
  against a host that overrides `default` only).
- When `runtimes.kata.kernelPackage` is null, skip the `overrideAttrs` on
  `pkgs.kata-runtime` and reference its `configuration-qemu.toml` directly
  — i.e. revert to the pre-`b46098f` behavior.
- Add `mkRemovedOptionModule` for `deployd.kata.enable` and
  `deployd.kata.kernelPackage` so anything stale fails with a clear
  pointer to the new options instead of a confusing eval error.
- Set `DEPLOYD_ALLOWED_RUNTIMES` and `DEPLOYD_DEFAULT_RUNTIME` env vars
  from the option values.
- Move the kata install block (`environment.systemPackages = [pkgs.kata-runtime]`,
  kernel modules, modprobe nested config, kata `configuration.toml`,
  `containerd.path`) to gate on `lib.elem "kata" cfg.runtimes.allowed`
  instead of `cfg.kata.enable`.

### 6. cc-sandbox

`packages/cc-sandbox/cc_sandbox.py:868`:

- Pass `runtime="runc"` in the deploy request body.
- Drop `devices=["/dev/kvm"]` — runc gives the container direct access to
  the host's `/dev/kvm` node via cgroup device permissions; no explicit
  passthrough needed. (Verify this by running `ls -l /dev/kvm` inside a
  test container before removing the line.)
- Update `deployd_deploy` signature to accept and serialize the new field.

### 7. Host config — erebonia

`hosts/erebonia/default.nix:31`: replace `kata.enable = true;` with:

```nix
runtimes = {
  allowed = ["kata" "runc"];
  default = "kata";  # preserves current behavior for non-cc-sandbox deploys
};
```

### 8. Delete kata-kernel-nested

After cc-sandbox is verified working with runc, remove:

- `packages/kata-kernel-nested/` (whole directory)
- The overlay entry in `flake.nix` registering `kata-kernel-nested`
- The `kata-kernel-config` drift check in `tests/default.nix`

Leave the `runtimes.kata.kernelPackage` option in the module (defaulting
to null) so a future custom kernel can be plugged in without re-adding
the plumbing.

### 9. Tests

- Unit: `validation::validate_runtime` cases (allowed, denied, none).
- Unit: executor resolves `None` → default, `Some(x)` → x. (May require
  extracting a helper function; current executor doesn't have a unit-test
  hook for this.)
- `tests/modules/deployd.nix:55` currently sets `kata.enable = false;`.
  Drop the line entirely — the new module default (`runtimes.allowed =
["runc"]`) is already what the test wants.
- New optional integration: a `runtimes.allowed = ["runc"]` host that
  rejects a `runtime: "kata"` deploy with a clear error.

## Sequencing

Land in this order so cc-sandbox is never broken:

1. **Protocol + helper + API + module changes** (steps 1–5, 7) as one PR.
   Steps 1–5 and step 7 must ship together: removing `kata.enable` from
   the module is breaking, so erebonia's migration to the new `runtimes`
   block has to be in the same commit. Erebonia keeps `kata` as default,
   and cc-sandbox keeps working unchanged because it doesn't yet set
   `runtime`.
2. **cc-sandbox switch to runc** (step 6). Verify nested KVM works inside
   a runc-launched cc-sandbox container before merging.
3. **Delete kata-kernel-nested** (step 8). Independent cleanup once nothing
   references it.

Steps 1 and 2 could be one PR if you want, but splitting makes the runc
verification an explicit checkpoint.

## Risks / things to verify

- **runc + /dev/kvm**: confirm a non-privileged runc container can open
  `/dev/kvm` under our cgroup config. If the device cgroup blocks it,
  cc-sandbox will need `--device=/dev/kvm` after all (just no kata layer).
  The validation allowlist already permits `/dev/kvm`, so this is a
  one-line fallback.
- **Kata kernel revert**: `modules/deployd/default.nix:515-522` does the
  `@KERNELPATH@` substitution unconditionally. When
  `runtimes.kata.kernelPackage` is null, skip the `overrideAttrs` and use
  `pkgs.kata-runtime` directly — same behavior as before commit
  `c1f4170`.
- **Audit-log compatibility**: appending the runtime field to entries is
  additive; downstream parsers (none yet) won't break.
- **Erebonia migration**: setting `runtimes.default = "kata"` preserves
  current behavior for any persistent kata containers. New cc-sandbox
  deploys explicitly request runc.

## Out of scope

- OAuth-group gating of runtime choice.
- Per-image runtime restrictions (e.g. "only cc-sandbox images may use runc").
- Replacing the kata-kernel-nested approach with something better (it's
  a future project, not part of this work).
