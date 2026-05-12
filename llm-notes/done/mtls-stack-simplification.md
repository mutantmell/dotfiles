# mTLS Stack Simplification

> **Status:** Phase A (SSHPOP) was unworkable — step-ca's SSHPOP provisioner
> only renews/rekeys/revokes SSH certs, it cannot issue x509. Replaced by the
> X5C-based fleet enrollment design — see `llm-notes/done/x5c-fleet-enrollment-plan.md`.
> Phase C implemented (2026-04-28). Phase B deferred — see "Implementation outcome"
> below. Reduces the operator-touch and conceptual surface of the recently-introduced
> fleet mTLS by collapsing three parallel identity systems (SSH host key / SSH host
> cert / x.509 client cert) onto a single CA and a single bootstrap path.
>
> **Related:** `observability-stack-migration.md` — that plan introduced the
> mTLS push endpoints. This plan reduces the cost of operating them.

---

## Motivation

Spinning up a new microvm currently requires three separate operator steps
across two scripts and one CA-key-on-laptop assumption:

1. `setup-guest.sh <parent> <guest>` — generates SSH host key, derives age
   key, **signs the host's SSH cert with `.keys/ssh_host_ca_key`** (an
   offline keypair on the operator's workstation), and updates
   `lib/common/data/host-certs/<guest>-cert.pub` in the repo.
2. `deploy-nixos-anywhere.sh <parent> ...` — re-runs `setup-guest.sh` for
   each guest as part of host install.
3. `issue-fleet-certs.sh [<host> ...]` — **separate** post-deploy step:
   the operator must have an active `step ca login` session (or a
   provisioner password file), the script mints an x.509 cert via
   step-ca's ACME provisioner, and SCPs `client.crt` + `client.key` to
   `/var/lib/fleet-tls/` on the host. Until this runs, the host's
   `fleet-tls-renew.service` errors at boot
   (`modules/common/tls-cert-client.nix:25`) and `fluent-bit-agent` can't
   push.

This produces three identities per host that don't form a chain of trust:

| Identity          | Issuer                            | Bootstrap                                  | Lives at                                |
| ----------------- | --------------------------------- | ------------------------------------------ | --------------------------------------- |
| SSH host key      | self-generated                    | nixos-anywhere extra-files                 | `/etc/ssh/ssh_host_ed25519_key`         |
| SSH host **cert** | offline `.keys/ssh_host_ca_key`   | `ssh-keygen -s` in `setup-guest.sh`        | `lib/common/data/host-certs/` (in repo) |
| mTLS client cert  | basel (step-ca, ACME provisioner) | operator-side `issue-fleet-certs.sh` + SCP | `/var/lib/fleet-tls/`                   |

basel already runs step-ca with ACME, OIDC (SSH user CA), and the x.509
intermediate. The SSH host CA and the fleet-cert issuance both bypass it
when they don't need to.

---

## Goals

In priority order:

1. **One operator step to enroll a new host**: deploy → host self-enrolls
   for the TLS client cert at first boot. No "remember to run X
   afterwards." No `step ca login` session on the operator's workstation.
2. **One source of truth for fleet membership**: `monitoredHosts` derived
   from `nixosConfigurations`, not a hand-maintained list.

Non-goals (deliberately out of scope):

- Replacing step-ca itself. It's already doing the right job.
- Changing the metrics/logs receiver chain on tharbad. mTLS-on-nginx with
  `$ssl_client_s_dn_cn` → `extra_label` works and isn't part of the cost.
- Touching SSH user cert flow (OIDC via Keycloak/Authelia). That's
  user-side identity; this plan is host-side identity.
- **Eliminating the offline SSH host CA** (`.keys/ssh_host_ca_key`). An
  earlier draft proposed moving SSH host signing into basel; that
  introduces a circular dependency for basel's own disaster recovery
  (basel can't sign its own host cert before it's running). See
  "Rejected alternatives" below.

---

## Phase A — SSHPOP self-enrollment (replaces `issue-fleet-certs.sh`)

**Independent of B and C. Highest single-step simplification.**

### Mechanism

step-ca's `SSHPOP` provisioner accepts an existing **SSH host certificate**
as proof-of-possession to mint an x.509 cert. Each host already has its
SSH host cert deployed at boot (under `/etc/ssh/`, signed by today's
offline SSH CA — or by step-ca after Phase B). The host can call:

```
step ca token <hostname>.internal --ssh-pop --ssh-pop-cert /etc/ssh/ssh_host_ed25519_key-cert.pub --ssh-pop-key /etc/ssh/ssh_host_ed25519_key
step ca certificate <hostname>.internal /var/lib/fleet-tls/client.crt /var/lib/fleet-tls/client.key --token <token>
```

…and self-enrolls. Renewal continues as today (`step ca renew` against
the existing cert, daily timer). The operator is no longer in the loop.

### Changes

**basel — add SSHPOP provisioner** in `step-ca.nix`:

```nix
authority.provisioners = [
  # ... existing acme + oidc ...
  {
    type = "SSHPOP";
    name = "fleet-sshpop";
    claims = {
      defaultTLSCertDuration = "8760h";
      maxTLSCertDuration = "8760h";
    };
  }
];
```

The SSHPOP provisioner trusts whatever the configured SSH host CA pubkey
is (`/etc/step-ca/data/ssh_host_ca.pub` — already in step-ca's config via
`ssh.hostKey`). Verify before Phase A rolls out that step-ca's loaded
SSH host CA pubkey matches `lib/common/data/pki/ssh_host_ca.pub`
(the one every host trusts). They were generated as a pair, but a
mismatch would silently reject every host's SSHPOP request.

**Each host — `modules/common/tls-cert-client.nix` rewrite**:

Replace the "renew-only, error-if-missing" model with a oneshot that
issues if missing then renews on the timer:

```nix
systemd.services.fleet-tls-bootstrap = {
  description = "Bootstrap fleet TLS client certificate via SSHPOP";
  wantedBy = [ "fluent-bit.service" ];
  before = [ "fluent-bit.service" ];
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];
  unitConfig.ConditionPathExists = "!/var/lib/fleet-tls/client.crt";
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
  };
  script = ''
    host=${config.networking.hostName}
    token=$(${pkgs.step-cli}/bin/step ca token "$host.internal" \
      --provisioner fleet-sshpop \
      --ssh-pop \
      --ssh-pop-cert /etc/ssh/ssh_host_ed25519_key-cert.pub \
      --ssh-pop-key /etc/ssh/ssh_host_ed25519_key \
      --ca-url ${caUrl} --root ${caRoot})
    ${pkgs.step-cli}/bin/step ca certificate "$host.internal" \
      /var/lib/fleet-tls/client.crt /var/lib/fleet-tls/client.key \
      --token "$token" \
      --san "$host" --san "$host.internal" \
      --ca-url ${caUrl} --root ${caRoot}
    chmod 640 /var/lib/fleet-tls/client.key
    chgrp fleet-tls /var/lib/fleet-tls/client.key
  '';
};
```

The existing `fleet-tls-renew.service` + timer stays; only its
"error if missing" branch goes away.

`fluent-bit.service` already gates on file presence indirectly (it errors
if the cert isn't readable). Adding `Requires=fleet-tls-bootstrap.service`

- `After=fleet-tls-bootstrap.service` to fluent-bit makes startup ordering
  explicit.

**Egress filter** — every monitored host gains an outbound rule to
`basel:443`. Some hosts (the management-zone ones) already have it for
ACME; DMZ hosts that currently can't reach basel directly will need one.
Audit during phase rollout: for each monitored host's `default.nix`,
ensure `mkEgressRules` includes `{ host = "basel"; proto = "tcp"; port = 443; }`.

**Delete** `scripts/issue-fleet-certs.sh`. The reminder line at the end
of `setup-guest.sh:244` goes away.

### Validation

Per host, after deploy:

```
journalctl -u fleet-tls-bootstrap          # ran once, success
ls -l /var/lib/fleet-tls/                  # client.crt + client.key present
journalctl -u fluent-bit -n 50             # no TLS errors
```

On tharbad:

```
curl -sk https://localhost:8427/api/v1/write -d 'foo' | head    # rejected (no client cert)
# vmsingle should show series with `host=<hostname>` for the new host within ~30s
```

### Rollback

Keep `issue-fleet-certs.sh` in the repo through phase A; if SSHPOP
proves unreliable, revert the `tls-cert-client.nix` change and run the
script manually. The SSHPOP provisioner can stay configured on basel
without harm — it's only invoked by hosts that try to use it.

---

## Phase B — Auto-derive `monitoredHosts`

**Independent of A. Smallest in scope; high payoff per line of code.
Renamed from "Phase C" in an earlier draft after the SSH-host-CA
consolidation was rejected.**

### Today

`lib/common/data/network.nix:195-218` is a hand-curated list of 16
hostnames. `modules/common/fluent-bit.nix:11-15` asserts that
`config.networking.hostName ∈ monitoredHosts` to catch typos. Adding a
new monitored host means:

1. Set `fluent-bit-agent.enable = true` in the host's `default.nix`.
2. Append the hostname to `monitoredHosts` in `network.nix`.
3. Forget step 2 → eval fails with the assertion message.

### Target

`monitoredHosts` is computed:

```nix
monitoredHosts = lib.attrNames (
  lib.filterAttrs
    (_: cfg: cfg.config.fluent-bit-agent.enable or false)
    self.nixosConfigurations
);
```

Drop the assertion in `fluent-bit.nix:11-15` — it can't fire anymore.

### Implementation cost (don't underestimate this)

The current registry is exposed as `pkgs.mmell.lib.data.network.monitoredHosts`,
which is built by an **overlay** (`overlays/mmell.nix` populates
`pkgs.mmell.lib`). Overlays don't naturally see `self.nixosConfigurations` —
the overlay is evaluated as part of `pkgs`, before any specific
nixosConfiguration is built; threading `self` in creates an evaluation
ordering you have to think about.

Three shapes, in increasing invasiveness:

1. **Pass `monitoredHosts` through `specialArgs` in `flake.nix`**, computed
   once at flake-output time. The overlay either still publishes a hardcoded
   list (defeats the purpose) or each module that wants `monitoredHosts`
   reads it from `specialArgs` instead of `pkgs.mmell.lib`. Touches every
   call site (~3 files), but call sites are simple.
2. **Move the registry off the overlay entirely** — make
   `lib/common/data/network.nix` consume `nixosConfigurations` directly,
   plumbed via `specialArgs`. Largest blast radius (every consumer of
   `pkgs.mmell.lib.data.network` changes), cleanest end state.
3. **Hybrid**: keep the overlay for everything _except_ `monitoredHosts`,
   which becomes a separate `self.lib.monitoredHosts` flake output.
   Smallest blast radius; introduces an asymmetry in where
   network-registry data lives.

**Recommend shape 3** — minimal disturbance, the asymmetry is documentable
in one sentence. But this is the part of the plan most likely to grow during
implementation; budget a session, not an hour.

The "instant payoff" framing in the original draft was optimistic. The end
state is right; the path there has a real cost.

### Validation

```
nix eval .#lib.common.data.network.monitoredHosts --json | jq
# Output should match today's hand-curated list. Diff against the old
# hardcoded array — empty diff = success.
```

Toggle `fluent-bit-agent.enable = true` on a host that's currently off
(if any), rebuild, confirm the host appears in the derived list and in
tharbad's blackbox/prometheus configs without further edits.

### Rollback

Trivial — revert the commit.

---

## Phase C — Smaller cleanups (do alongside or after A)

These don't merit phases of their own but are cheap once A is in flight.

- **Collapse `modules/common/tls-cert-client.nix` into
  `modules/common/fluent-bit.nix`.** The cert client is only ever
  enabled by fluent-bit; the split into two common modules with one
  cross-enabling the other is artificial. After Phase A, `tls-cert-client`
  is short enough (timer + bootstrap unit + persistence) to inline.
- **Document or drop the Loki mTLS endpoint.** Per
  `observability-stack-migration.md:178`, log label binding is
  best-effort regardless — nginx can't rewrite Loki's protobuf push
  payload. The mTLS on `:3100` therefore enforces "you are _some_ fleet
  host" but not "you are _this_ host." Either accept that and keep
  mTLS for the audit trail (`$ssl_client_s_dn_cn` in nginx logs) or
  drop it back to plain HTTPS to remove the "wait, why is this
  protected differently from metrics" cognitive cost. Recommend keeping
  but adding a one-line comment in `ingress.nix` explaining the asymmetry.
- **Delete `tharbad/modules/prometheus.nix`** once Phase 5 of the
  observability migration completes (already noted there; flagged here
  because the file currently still references `monitoredHosts` and
  blocks Phase C cleanup of network.nix unless Phase 5 lands first or
  prometheus.nix's scrape list is migrated to derive from
  `nixosConfigurations` directly).

---

## Net effect on "spin up a new microvm"

**Today (5 operator-visible steps):**

```
1. edit hosts/<parent>/microvm/guests/<new>/default.nix
2. edit lib/common/data/network.nix (add to monitoredHosts)
3. ./scripts/setup-guest.sh <parent> <new> [--target ... | --output-dir ...]
4. (nixos-rebuild on parent, or deploy-nixos-anywhere if first install)
5. ./scripts/issue-fleet-certs.sh <new>
```

**After A+B (3 operator-visible steps):**

```
1. write hosts/<parent>/microvm/guests/<new>/default.nix
2. ./scripts/setup-guest.sh <parent> <new> --target <parent>
3. nixos-rebuild — host self-enrolls for the TLS cert at first boot
```

The SSH host cert is still signed by `setup-guest.sh` against the offline
CA, exactly as today. Step 5 (the post-deploy `issue-fleet-certs.sh`) is
gone; step 2 (manually appending to `monitoredHosts`) is gone.

---

## Sequencing

Two independent phases plus opportunistic cleanups. Recommended order:

1. **Phase A first** (highest single-step bootstrap simplification; the
   biggest user-visible win). Validate against one canary host before
   rolling fleet-wide.
2. **Phase B second** (auto-derive `monitoredHosts`). Independent of A
   but lower urgency — the assertion catches the "forgot to update
   registry" mistake today, so the pain is small.
3. **Phase C cleanups** any time after A.

Each phase is independently revertable. None require a fleet-wide
redeploy in lockstep — they propagate per-host as hosts get rebuilt.

---

## Risks & mitigations

| Risk                                                                                                                                                    | Mitigation                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SSHPOP provisioner mis-validates the SSH cert and rejects valid hosts.                                                                                  | Phase A keeps `issue-fleet-certs.sh` in the repo; revert `tls-cert-client.nix` to its current form, run the script manually, file an issue against step-ca with the rejection message.                                                                                                                                 |
| Some DMZ host can't reach `basel:443` for SSHPOP enrollment.                                                                                            | Audit egress rules in each monitored host's `default.nix` during Phase A rollout — most management-zone hosts already permit it for ACME; DMZ hosts may need a new outbound allowance.                                                                                                                                 |
| step-ca's loaded SSH host CA pubkey (used by SSHPOP to verify host certs) doesn't match `lib/common/data/pki/ssh_host_ca.pub`.                          | Phase A first checkpoint: extract step-ca's pubkey, diff against the repo. They were generated as a pair, but a mismatch silently breaks every enrollment.                                                                                                                                                             |
| First-boot network race — fluent-bit-bootstrap fires before DNS resolves `basel.internal` or before basel is reachable.                                 | `Requires=network-online.target` + `After=` should cover the common case; harder edges (basel itself rebooting at the same time as a host) just retry — make the bootstrap unit `Restart=on-failure` with a backoff. New failure mode that didn't exist when the cert was pre-placed; document so it's not surprising. |
| SSHPOP slightly broadens per-host blast radius: stealing a host's SSH host private key now also lets an attacker mint x.509 client certs for that host. | Bounded — the cert is locked to the host's identity, can't impersonate peers — and an attacker with the SSH host key can already SSH-impersonate the host, so the marginal impact is small. Document and accept.                                                                                                       |
| New-host enrollment depends on basel being up at first boot.                                                                                            | Acceptable expansion of an existing dependency (basel-down already blocks cert renewal after ~1y, ACME, Keycloak login). New hosts are infrequent; if basel is down, defer the deploy. The bootstrap unit retries, so if basel comes up later the cert lands without intervention.                                     |
| Phase B breaks if a `nixosConfigurations` entry sets `fluent-bit-agent.enable` but isn't a real fleet host (e.g. a CI eval).                            | The filter is over `nixosConfigurations` only; CI/test hosts that aren't deployed don't enable the agent. If there's a future eval-only host, gate via `cfg.config.networking.hostName != "ci-eval"` or similar.                                                                                                       |
| `monitoredHosts` ordering changes after Phase B, breaking blackbox scrape job names if any are derived from list index.                                 | The derived list uses `lib.attrNames` which is alphabetic; current registry happens to be deploy-order-ish. Confirm no consumer relies on order — `tharbad/modules/fluent-bit.nix` uses `map host: ...` over the list, order doesn't affect output.                                                                    |
| Phase B's overlay-vs-`nixosConfigurations` threading is more invasive than first sketched.                                                              | See "Implementation cost" inside Phase B. Pick shape 3 (split `monitoredHosts` out of the overlay) for minimal blast radius; if even that is rough, defer Phase B — it's the lower-priority phase and the current assertion is a working guardrail.                                                                    |

---

## Open questions

1. **Should `tls-cert-client` be folded into `fluent-bit-agent`
   directly (Phase C), or kept generic for future non-fluent-bit
   consumers (e.g. NFS-over-mTLS, mTLS for incus services)?** Lean
   _fold in_: there are no concrete near-term consumers, and the abstraction
   was speculative. Easy to extract again if a second consumer appears.
2. **Phase A SAN list — is `<host>.internal` enough, or also include
   `<host>.internal.mutantmell.net`?** Today's
   `issue-fleet-certs.sh:82` sets both. Match that; document why if
   one ever gets dropped (current nginx mTLS only checks CN, not SAN,
   so this is mostly forward-compat).
3. **Should the SSHPOP provisioner be locked down to specific
   principals?** step-ca's `ssh.host` policy already restricts which
   principals can appear in _issued_ SSH certs; SSHPOP itself just
   accepts whatever cert the client presents. A leaked SSH host key
   for `bose` could call SSHPOP and ask for an x.509 cert with
   `CN=bose` (which it's entitled to anyway). Worth confirming the
   nginx-side `extra_label=host=$ssl_client_s_dn_cn` mapping can't
   be tricked by a SAN-vs-CN mismatch.

---

## File touchpoints

```
# Phase A
modules/common/tls-cert-client.nix             [MOD]   add bootstrap oneshot, drop "error if missing"
modules/common/fluent-bit.nix                  [MOD]   Requires=fleet-tls-bootstrap on fluent-bit
hosts/calvard/microvm/guests/basel/modules/step-ca.nix   [MOD]   add SSHPOP provisioner
hosts/<each>/.../default.nix                   [MOD]   ensure egress allows basel:443 (audit)
scripts/issue-fleet-certs.sh                   [DEL]
scripts/setup-guest.sh                         [MOD]   drop the post-deploy reminder line

# Phase B
flake.nix                                      [MOD]   compute monitoredHosts from nixosConfigurations
lib/common/data/network.nix                    [MOD]   monitoredHosts becomes a parameter or moves
modules/common/fluent-bit.nix                  [MOD]   drop the assertion
overlays/mmell.nix (or wherever)               [MOD]   stop publishing monitoredHosts via the overlay

# Phase C
modules/common/tls-cert-client.nix             [DEL]   inlined into fluent-bit
modules/common/fluent-bit.nix                  [MOD]   absorbs tls-cert-client config
hosts/calvard/microvm/guests/tharbad/modules/ingress.nix   [MOD]   comment on Loki mTLS asymmetry
```

---

## Implementation outcome (2026-04-28)

**Phase A — done.** SSHPOP self-enrollment is live:

- `fleet-sshpop` provisioner added to step-ca (`hosts/calvard/microvm/guests/basel/modules/step-ca.nix`).
- `fleet-tls-bootstrap` oneshot + `fleet-tls-renew` daily timer in
  `modules/common/fluent-bit.nix` (units use `StateDirectory=fleet-tls`
  - `Group=fleet-tls` so the directory is created with correct ownership
    on Incus VMs that lack `/persist`).
- fluent-bit ordering uses `After=` only — not `Requires=` — so the
  upstream `Restart=always` retries until bootstrap eventually writes
  the cert.
- A build-time assertion in `fluent-bit.nix` blocks any monitored host
  whose SSH host cert isn't checked in to `lib/common/data/host-certs/`,
  since SSHPOP can't enroll without it.
- `scripts/issue-fleet-certs.sh` deleted; setup-guest.sh reminder dropped.

**Phase B — deferred.** `monitoredHosts` is still hand-curated in
`lib/common/data/network.nix`. The plan's three implementation shapes all
assumed the fleet was reachable through `self.nixosConfigurations`, but
microvm guests live under `microvm.vms.<name>.config` on each parent
host, and Incus VMs are evaluated through `mk-incus-vm` /
`mk-incus-container` without being attached to a flake output. Filtering
`self.nixosConfigurations` would give us only the four parent hosts,
silently dropping the rest of the fleet.

The existing assertion (`hostName ∈ monitoredHosts`) is a working build-time
guardrail, and the new SSH-host-cert assertion is a second one. Together
they cover the failure modes Phase B was meant to prevent. Revisit if
either grows real friction, or if a future refactor lands a
flake-output-level enumeration of guest configs.

**Phase C — done.** `tls-cert-client.nix` deleted and inlined into
`fluent-bit.nix` (gated on `hasTls`, so tharbad — which talks to its
own localhost — skips cert management cleanly). Loki mTLS asymmetry
documented in `tharbad/modules/ingress.nix`. The `monitoredHosts` import
in `tharbad/modules/prometheus.nix` was already removed in commit 773172d,
unblocking this work.

**Net effect on "spin up a new microvm":** 5 → 3 operator steps for hosts
whose pubkey is already in `keys.json`. The pre-Phase-A bottleneck
(`issue-fleet-certs.sh` + an active `step ca login` session on the
laptop) is gone. The remaining manual step is the `monitoredHosts` edit
that Phase B would have automated.

---

## Rejected alternatives

### Moving the SSH host CA into step-ca

**Earlier draft proposal:** consolidate the offline SSH host CA
(`.keys/ssh_host_ca_key`) into basel's step-ca, treating SSH host certs
the same way step-ca already treats SSH user certs and x.509 certs. End
state: one CA hierarchy on basel for everything; delete
`apps/ssh-host-cert-sign.nix`, `lib/common/data/host-certs/`, and the
operator-side offline keypair.

**Why rejected:** circular dependency for basel's own disaster
recovery. basel is itself a microvm guest — it has an SSH host key and
needs an SSH host cert like every other host. If basel is the SSH host
CA _and_ the consumer of that CA, then a clean rebuild of basel
(post-disko, post-impermanence-wipe) requires basel to sign its own
host cert _before it's running_. That's chicken-and-egg.

Workarounds existed but each had its own cost:

- Bootstrap basel manually with a self-signed cert during DR, then
  re-sign once basel is up. Operationally ugly under pressure; easy
  to mis-execute during a recovery scenario.
- Retain an offline keypair specifically for basel's own cert. Defeats
  the consolidation — we'd still have an offline key, just used in
  one place instead of fourteen.
- Accept that basel DR uses a different procedure than every other
  host. Adds asymmetric special-casing exactly where the rest of the
  plan tries to remove it.

The conceptual win ("one CA hierarchy") is real but mostly aesthetic.
The 14 pre-signed cert files in `lib/common/data/host-certs/` aren't
actively painful — they're checked-in build artifacts that work, and
the offline SSH host CA is rarely touched (only when adding a host
or rotating). The cost-benefit didn't justify the new DR complexity.

If this becomes more attractive later (e.g. step-ca gains
self-bootstrap-from-saved-state, or the offline key handling becomes
a real pain point), revisit. The trust-side configuration
(`modules/common/ssh-cert-client.nix`) doesn't change either way, so
the path forward stays open.

### Keeping `issue-fleet-certs.sh` and just smoothing it

A weaker form of Phase A: keep the operator-driven cert issuance, but
have `setup-guest.sh` invoke `issue-fleet-certs.sh` automatically
after deploy. Fewer manual steps, but the operator's `step ca login`
session is still required, and the SCP-from-laptop link in the chain
of trust stays. SSHPOP eliminates both of those structurally; the
half-measure isn't worth the partial cleanup.
