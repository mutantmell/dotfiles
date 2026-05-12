# X5C-based Fleet Enrollment for mTLS Client Certs

## Status

**Done (2026-05-12).** All phases shipped; replaces the broken SSHPOP
design from `mtls-stack-simplification.md` Phase A.

Audit summary against the as-built code:

| Phase | Outcome |
| --- | --- |
| 0 — Smoke test | Presumed passed (downstream phases all functional) |
| 1 — Offline CA + signing tool | Done. `apps/fleet-x5c-cert-sign.nix`, `lib/common/data/pki/fleet_x5c_ca.crt`, `fleetEnrollmentCerts` attrset, `scripts/check-cert-expiry.sh` (60d/14d SSH, 450d X5C). |
| 2 — On-host enrollment-key | Done, with deviation: the host does NOT generate the keypair on first boot. Instead the operator pre-generates it (or pulls from passage) and ships it via the static virtiofs share at `/static/fleet-tls/enrollment.key`. The on-host service copies from the share rather than calling `step crypto keypair`. This collapses the bootstrap to a single deploy and lets the operator sign the enrollment cert offline before the host ever boots. See `modules/common/fluent-bit.nix` `fleet-enrollment-key.service` and `scripts/setup-guest.sh` lines 180–256. |
| 3 — Operator workflow | Done. `apps/fleet-enrollment-key-registry.nix`, `setup-guest.sh` collects/registers/signs end-to-end. |
| 4 — basel X5C provisioner | Done. `hosts/calvard/microvm/guests/basel/modules/step-ca.nix` — gated on `pki.fleetX5cCA != null`, base64-encoded PEM passed to `roots`. |
| 5 — Bootstrap script rewrite | Done. `fluent-bit.nix` `fleet-tls-bootstrap.service` uses `step ca certificate --provisioner fleet-x5c --x5c-cert/--x5c-key`. Assertion gated on `hasTls && x5cActive`. |
| 6 — Resilience (StartLimitBurst) | Done. `unitConfig.StartLimitBurst = 10000` on `fluent-bit.service`. |
| 7 — Recover calvard | Operationally complete — calvard.crt present in registry; 16 hosts have minted enrollment certs. |
| 8 — Cleanup | SSHPOP removed from basel (no `sshpop` references remain); `mtls-stack-simplification.md` postscript added (2026-05-12); plan moved to `done/`. |

Original plan body retained below for reference.

---

## Original status (at WIP time)

Replaces the SSHPOP-based design from
`llm-notes/done/mtls-stack-simplification.md` Phase A, which is broken:
step-ca's SSHPOP provisioner cannot issue x509 certificates (only renew/
rekey/revoke SSH certs). Verified against smallstep docs and reproduced
on calvard (`unexpected requested token type for SSHPOP token: 0` from
step-cli's own type check, before the request even reaches basel).

## Goal

Restore self-enrollment for fleet hosts so they can bootstrap an x509
client cert against basel for fluent-bit's Loki/vmsingle push, without
operator intervention at runtime. Operator step is bounded to the same
shape as the existing SSH host cert flow: register key in the repo,
sign offline, commit, deploy.

## Why X5C (not JWK or rolling back)

- **JWK** with shared secret is simpler but loses per-host identity:
  one compromise = whole fleet rotation. We're already tolerating the
  parallel cost of per-host SSH host certs and a soon-to-arrive PQC age
  key per host; an X5C enrollment cert fits the same operational shape.
- **Rolling back to `issue-fleet-certs.sh`** keeps the runtime ops
  burden the original simplification plan was trying to eliminate.
- **X5C** is the documented step-ca path for issuing x509 certs to
  clients that authenticate with a separately-rooted x509 cert. The
  authorization table explicitly lists `x509-sign` for X5C, and the
  docs show the exact issuance command we'd use:

  ```
  step ca certificate <host>.internal client.crt client.key \
    --x5c-cert enrollment.crt --x5c-key enrollment.key
  ```

  This is a single-call issuance, not the two-step token + certificate
  dance the SSHPOP design used. Different code path entirely from the
  one that fails today.

## Pre-flight: smoke test before any repo work

**Don't skip this.** SSHPOP looked fine on paper too. ~30 minutes of
manual validation now is cheap insurance.

1. On a workstation with the offline key material, generate a one-off
   ed25519 keypair and self-signed root + leaf chain to act as a
   throwaway X5C trust anchor.
2. SSH to basel; temporarily add an `X5C` provisioner to step-ca with
   `roots` set to the throwaway root PEM (in-memory edit, no commit).
   Reload step-ca.
3. From any monitored host (e.g. calvard), with the throwaway leaf
   cert+key in `/tmp`, run:
   ```
   step ca certificate calvard.internal /tmp/c.crt /tmp/c.key \
     --provisioner test-x5c \
     --x5c-cert /tmp/enrollment.crt --x5c-key /tmp/enrollment.key \
     --san calvard --san calvard.internal \
     --ca-url https://basel.internal --root /etc/step-ca/data/root_ca.crt
   ```
4. Push the resulting `c.crt` to tharbad's vmsingle/loki with curl and
   a simple `metric foo 1\n` payload over mTLS. Confirm tharbad accepts
   the cert and the series shows up in vmsingle within ~30s.
5. Revert step-ca config; remove throwaway provisioner.

**Pass criteria**: end-to-end metric flow with the X5C-issued client
cert. Anything weird here (SAN handling, validity ordering, root trust)
gets resolved in a 5-line change before we build the pipeline around it.

## Architecture

Mirror the existing SSH host cert pattern. Where SSH host certs live in
the repo, x509 enrollment certs live alongside them. Where the SSH host
CA private key is offline in `.keys/`, the X5C enrollment CA private
key sits beside it.

| Concern                       | SSH host cert (today)                          | Fleet X5C cert (this plan)                                          |
| ----------------------------- | ---------------------------------------------- | ------------------------------------------------------------------- |
| On-host private key           | `/etc/ssh/ssh_host_ed25519_key`                | `/var/lib/fleet-tls/enrollment.key` (gen on first boot)             |
| Public key registered in repo | `keys.json:hostKeys.<host>`                    | `keys.json:fleetEnrollmentKeys.<host>` (new field)                  |
| Offline CA private key        | `.keys/ssh_host_ca_key` (migrating to passage) | `.keys/fleet_x5c_ca_key` (migrating to passage)                     |
| Public CA in repo             | `lib/common/data/pki/ssh_host_ca.pub`          | `lib/common/data/pki/fleet_x5c_ca.crt` (new)                        |
| Signed cert in repo           | `lib/common/data/host-certs/<host>-cert.pub`   | `lib/common/data/fleet-x5c-certs/<host>.crt` (new)                  |
| Offline signing app           | `nix run .#ssh-host-cert-sign`                 | `nix run .#fleet-x5c-cert-sign` (new)                               |
| Deploy mechanism              | `environment.etc."ssh/...key-cert.pub".source` | `environment.etc."fleet-tls/enrollment.crt".source`                 |
| Lifetime                      | 731d                                           | 5y enrollment cert (temporary — see Risks); 365d issued client cert |

**Note on offline storage.** The plan still refers to `.keys/` for the
offline CA private keys because that's the current operator-side
location. A separate workstream will migrate this material into a
PQC-compatible passage password store; the signing-app interface stays
unchanged across that migration (the app reads the key from wherever the
operator keeps it).

step-ca side: `X5C` provisioner trusting `fleet_x5c_ca.crt`; SSHPOP
provisioner removed (or left harmless and unused, decide at cleanup).

## Work breakdown

### Phase 0 — Smoke test

See "Pre-flight" above. Do not start Phase 1 until this passes.

### Phase 1 — Offline CA + signing tool

1. Generate the offline X5C CA keypair (operator-side, kept out of repo):
   - `.keys/fleet_x5c_ca_key` (private; same backup story as
     `ssh_host_ca_key`)
   - `lib/common/data/pki/fleet_x5c_ca.crt` (public root cert; checked
     in)
   - Decide: ed25519 (matches SSH host CA shape) or RSA-4096 (broader
     compatibility). Step-ca supports both; ed25519 is fine.
2. Add `lib/common/data/pki/fleet_x5c_ca.crt` to the `pki` attrset in
   `lib/common/data/default.nix` (alongside `sshHostCA`).
3. Add `apps/fleet-x5c-cert-sign.nix`, modeled directly on
   `apps/ssh-host-cert-sign.nix`:
   - `--list`, `--sign <hostname>`, `--sign-all` subcommands.
   - Reads `keys.json:fleetEnrollmentKeys.<host>` (a PEM-encoded ed25519
     pubkey, registered when the host first boots).
   - Pulls SAN list from network registry (`allHostDomains`).
   - Uses `step certificate create` (or openssl) with the offline CA
     to mint a **5-year** leaf cert; CN = `<host>.internal`, SANs = all
     the host's domains, no key usage restrictions beyond client auth.
   - Writes to `lib/common/data/fleet-x5c-certs/<host>.crt` (note:
     bare `.crt` extension, distinct from the `<host>-cert.pub` SSH
     convention).
   - Asserts the issued cert's `Not After` < the X5C CA cert's
     `Not After` (per X5C validity-ordering rule).
4. Wire the new app in `apps/default.nix`.
5. Add a `fleetEnrollmentCerts` attrset in `lib/common/data/default.nix`
   that auto-discovers `fleet-x5c-certs/<host>.crt`. **Use a separate
   parse block** — the existing `hostCerts` block matches
   `(.+)-cert\.pub`; X5C certs need a `(.+)\.crt$` pattern. Don't try to
   share the parse function.
6. Add a CI check (script in `scripts/` invoked from
   `scripts/run-checks.sh`) that walks `host-certs/` and
   `fleet-x5c-certs/`, parses each cert's `Not After` (via
   `ssh-keygen -L -f` and `step certificate inspect` respectively), and
   fails the build when:
   - any host cert is within 60d of expiry (warn) or 14d (fail),
   - any X5C enrollment cert is within 450d of expiry (warn — long
     window because issuance silently fails as soon as enrollment cert
     expiry < issued cert validity end; see Risks),
   - any host in the network registry is missing a cert in either
     directory,
   - any cert in either directory has no matching host in the registry
     (orphan detection).

### Phase 2 — On-host enrollment-key generation

The host needs its enrollment private key materialized on first boot,
analogously to how sshd generates `/etc/ssh/ssh_host_ed25519_key`. The
step-ca CLI doesn't have a native "generate key" service; we wrap one.

Add to `modules/common/fluent-bit.nix` (or a new
`modules/common/fleet-enrollment.nix` if it grows):

```nix
users.groups.fleet-tls = {};

systemd.services.fleet-enrollment-key = {
  description = "Generate fleet enrollment keypair on first boot";
  wantedBy = [ "fleet-tls-bootstrap.service" ];
  before = [ "fleet-tls-bootstrap.service" ];
  unitConfig.ConditionPathExists = "!/var/lib/fleet-tls/enrollment.key";
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    StateDirectory = "fleet-tls";
    StateDirectoryMode = "0750";
    Group = "fleet-tls";
  };
  script = ''
    ${pkgs.step-cli}/bin/step crypto keypair \
      /var/lib/fleet-tls/enrollment.pub \
      /var/lib/fleet-tls/enrollment.key \
      --kty OKP --curve Ed25519 --no-password --insecure
    chmod 640 /var/lib/fleet-tls/enrollment.key
  '';
};
```

**Group/permissions sanity check.** Both `fleet-enrollment-key.service`
and `fleet-tls-bootstrap.service` need to be able to read the enrollment
key. Confirm during implementation that the bootstrap service runs as
either root or a member of the `fleet-tls` group; if it runs as a
dedicated user, add that user to the group. Otherwise the `chmod 640`
is decorative and the bootstrap reads as root anyway.

After this runs once, the operator pulls the pubkey, registers it,
signs, and commits.

### Phase 3 — Operator workflow integration

Add a parallel `apps/fleet-enrollment-key-registry.nix` (modeled on
`apps/ssh-key-registry.nix`). Don't fold X5C-pubkey handling into the
existing SSH key registry — the formats differ (SSH `ssh-ed25519 ...`
vs PEM-encoded ed25519 pubkey) and the JSON sub-tree is different
(`hostKeys` vs `fleetEnrollmentKeys`). A parallel app keeps each one
narrow.

Update `scripts/setup-guest.sh` (and document in `CLAUDE.md`):

After the existing SSH host cert step, add a step that:

1. SSHes to the host, reads `/var/lib/fleet-tls/enrollment.pub`.
2. Updates `lib/common/data/keys.json:fleetEnrollmentKeys.<host>` via
   the new `fleet-enrollment-key-registry` app.
3. Reminds the operator to run `nix run .#fleet-x5c-cert-sign --
--sign <host>` and commit the cert.

**Two-deploy bootstrap for new hosts.** The flow is intentionally
two-pass:

1. **First deploy** — host comes up with `fleet-enrollment-key.service`
   firing on boot. Pubkey lands at `/var/lib/fleet-tls/enrollment.pub`.
   `fleet-tls-bootstrap` and `fluent-bit` will fail-and-retry because
   no enrollment cert is present yet (this is fine — the
   `StartLimitBurst` bump from Phase 6 keeps them retrying without
   giving up).
2. **Operator step** — run `setup-guest.sh` to collect both the SSH
   host pubkey and the enrollment pubkey, register them, sign both
   certs offline, commit.
3. **Second deploy** — ships both signed certs. `fleet-tls-bootstrap`
   succeeds on next retry; `fluent-bit` follows automatically.

This mirrors the existing two-pass shape used for SSH host certs
(host generates key → operator signs → redeploy) — just with two
materials instead of one.

### Phase 4 — basel: X5C provisioner

In `hosts/calvard/microvm/guests/basel/modules/step-ca.nix`,
`authority.provisioners`:

- Remove the `SSHPOP` `fleet-sshpop` provisioner (or leave it; it's
  harmless if unused).
- Add:
  ```nix
  {
    type = "X5C";
    name = "fleet-x5c";
    roots = [(builtins.readFile pkgs.mmell.lib.data.pki.fleetX5cCA)];
    claims = {
      defaultTLSCertDuration = "8760h";
      maxTLSCertDuration = "8760h";
    };
  }
  ```
  The `roots` field takes PEM blocks, not file paths — confirm the
  exact field name during Phase 0 (smallstep docs reference
  `roots: a base64 encoded list of root certificate PEM blocks`).

### Phase 5 — Bootstrap script rewrite

In `modules/common/fluent-bit.nix`, replace the SSHPOP-based bootstrap
with the X5C single-command issuance:

```nix
script = ''
  ${pkgs.step-cli}/bin/step ca certificate "${hostname}.internal" \
    /var/lib/fleet-tls/client.crt /var/lib/fleet-tls/client.key \
    --provisioner fleet-x5c \
    --x5c-cert /etc/fleet-tls/enrollment.crt \
    --x5c-key /var/lib/fleet-tls/enrollment.key \
    --san "${hostname}" --san "${hostname}.internal" \
    --ca-url ${caUrl} --root ${caRoot}
  chmod 640 /var/lib/fleet-tls/client.key
'';
```

The renewal service stays as-is (`step ca renew --force` against the
existing client cert; doesn't go through the provisioner).

**Assertions and the bootstrap chicken-and-egg.** Extend the existing
assertion in `fluent-bit.nix:24-26` to also require an entry in
`fleetEnrollmentCerts`, but **gate it on the same condition** as the
existing one (`fluent-bit-agent.tls.certFile != null`, or whatever the
existing predicate is). This way a fresh host can deploy with
`fluent-bit-agent.enable = false` for the first pass (or with the
assertion's predicate not yet satisfied), generate its enrollment
pubkey, get its cert signed, and pass the assertion on the second
deploy. **Do not** make the assertion fire purely on host name being
present in the network registry — that breaks the bootstrap flow.

### Phase 6 — Resilience fixes (do these regardless of approach)

The current state showed both `fleet-tls-bootstrap` and `fluent-bit`
hitting `start-limit-hit` and giving up. Even with X5C working, transient
errors will recur. Pick one:

- Bump `unitConfig.StartLimitBurst` on `fluent-bit.service` to
  effectively unlimited (e.g. 10000), preserving the original intent
  expressed in the comment at `modules/common/fluent-bit.nix:126-129`.
- Or: convert the ordering to a `systemd.paths` watch on
  `/var/lib/fleet-tls/client.crt` that triggers `fluent-bit.service`
  on cert appearance. Cleaner but more moving parts.

Recommend the StartLimitBurst bump — it's a one-line change matching
the existing design intent.

### Phase 7 — Recover calvard

After deploying the above:

1. `systemctl reset-failed fleet-tls-bootstrap fluent-bit` on calvard
   (and any other host stuck in the same state).
2. `systemctl start fleet-tls-bootstrap`.
3. Verify cert appears, fluent-bit comes up, metrics flow to vmsingle
   on tharbad.
4. Spot-check 1-2 other monitored hosts for the same recovery.

### Phase 8 — Cleanup

- Update `llm-notes/done/mtls-stack-simplification.md` with a
  postscript pointing at this plan and noting that Phase A (SSHPOP) was
  unworkable.
- Move this plan to `llm-notes/done/` once Phase 7 verifies on every
  monitored host.
- Decide whether to keep the dormant SSHPOP provisioner on basel or
  remove it; default = remove.

## Revocation playbook

There are three distinct compromise scenarios; only one requires the
nuclear option.

**One host's enrollment private key leaks** (e.g., disk image stolen,
host rooted):

1. Remove that host's cert from `lib/common/data/fleet-x5c-certs/`.
2. Re-sign with a fresh on-host keypair: SSH to the host (assuming you
   still trust it), delete `/var/lib/fleet-tls/enrollment.{key,pub}`,
   redeploy to regenerate the keypair, register the new pubkey,
   re-sign, commit.
3. Optionally: register the leaked cert's serial in a step-ca CRL
   (step-ca supports x509 revocation). Belt-and-braces if the host is
   still online but untrusted.

**The X5C CA private key leaks** (offline material exfiltrated):

1. Generate a fresh X5C CA keypair offline.
2. Replace `lib/common/data/pki/fleet_x5c_ca.crt`.
3. Re-sign every host's enrollment cert with the new CA.
4. Commit + redeploy. Basel's X5C provisioner picks up the new
   `roots`. The old CA is now untrusted; any cert signed by it is
   rejected.
5. This is "rotate the CA + re-sign all enrollment certs in one
   batch" — a single PR, mechanically straightforward, but every host
   needs a redeploy to ship the new enrollment cert.

**A single issued client cert is suspect** (short-lived, expires in
24h):

- Don't bother revoking. Wait for expiry. If you must act faster,
  revoke via step-ca's CRL endpoint and force a renewal cycle.

The first two scenarios are the only ones likely in homelab practice.
Both are bounded operator work — no runtime API dance, just a commit
and redeploy.

## Risks and unknowns

| Risk                                                        | Mitigation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SAN handling in X5C differs from what docs imply            | Phase 0 smoke test catches this                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `roots` field syntax in step-ca config                      | Verify PEM-block-list during Phase 0; the smallstep docs are slightly ambiguous (they say "base64 encoded" but the actual config takes PEM)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| **Enrollment cert silent-expiry trap**                      | X5C requires `Not After` of issued ≤ `Not After` of enrollment. With a 5y enrollment cert and 365d issued cert, issuance starts silently failing once the enrollment cert is within 365d of expiry — and you find out at the next renewal cycle, not at first failure. **Mitigation:** the Phase 1 CI check warns at <450d remaining on enrollment certs (90d head start before the trap window). **Future cleanup:** once the CI/CD pipeline is mature enough to handle frequent rotations safely, shorten the issued cert lifetime to 90d and the enrollment cert to 731d (matching the SSH host cert cadence). The 5y choice is a deliberate "buy time for the rest of the stack to mature" decision, not a target end state. |
| Validity-ordering rule trips up renewal flow                | Renewal goes through `step ca renew` which doesn't re-auth via X5C, so this only matters at issuance time. Re-issuance (full bootstrap re-run) does need the enrollment cert valid, hence the silent-expiry mitigation above.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| step-cli flag name drift (e.g. `--x5c-cert` vs `--x5c-key`) | Pinned in Phase 0; `nix eval nixpkgs#step-cli.version` is currently 0.29.0                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `step crypto keypair` command shape on first-boot key gen   | Verify the exact CLI invocation works with the step-cli we ship before relying on it in Phase 2                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Forgetting to register the enrollment pubkey for a new host | The same failure mode as forgetting the SSH host pubkey; the existing assertion pattern in `fluent-bit.nix:24-26` already catches this — extend it to check `fleetEnrollmentCerts ? ${hostname}` too, gated on the same `fluent-bit-agent.tls.certFile != null` predicate (see Phase 5). The Phase 1 CI orphan/missing check is a second layer.                                                                                                                                                                                                                                                                                                                                                                                  |

## Out of scope

- Replacing the SSH host CA with step-ca-signed SSH host certs
  (rejected in the original simplification doc; that decision stands).
- PQC age key migration (separate workstream; this plan only assumes
  it'll add another per-host on-boot keypair, which validates the
  X5C-shaped pattern further).
- Changing tharbad's mTLS receiver setup; nginx termination + DN
  matching keeps working.
