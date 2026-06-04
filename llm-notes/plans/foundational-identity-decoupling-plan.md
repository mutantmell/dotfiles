# Foundational Identity Decoupling Plan

Status: Planned (not started)

Date: 2026-06-04

## What this is

A plan to make the homelab's **foundational operator access** fully
independent of the **rich identity provider** (lldap + Authelia), so that the
rich IdP can later move "up a layer" — out of the foundational microvm fleet
and (eventually) into the planned k3s cluster — without making operational
access to tier-1 hosts depend on the thing being moved.

The driving principle (developed across the identity discussion that
produced this plan): **operational access to layer N must root in identity at
layer ≤ N, never upward.** The rich IdP is the one piece of identity that we
*want* to be dynamic; everything the foundation needs to be operated must keep
working with the rich IdP down.

## Relationship to other plans

- **Enables / unblocks** `llm-notes/plans/k3s-cluster-bootstrap-plan.md` —
  specifically its identity open-decisions (operator `kubectl` access path and
  PKI overlap). Moving lldap/Authelia into the cluster is only safe once the
  foundation no longer depends on them; this plan establishes that
  precondition. The bootstrap plan cross-references this document.
- **Depends on / follows** `llm-notes/wip/authelia-migration-plan.md` — that
  migration made Authelia the live OIDC provider for step-ca (Phase 2c,
  2026-06-04). This plan builds on that end-state. Keycloak removal
  (authelia-migration Phase 3) is independent of this plan.
- **Interacts with** the observability stack
  (`llm-notes/done/observability-stack-migration.md`) — Perses on tharbad is
  one of the rich-IdP consumers this plan addresses (Phase C).

---

## Thesis

The foundation is **already ~90% declarative and IdP-independent.** Adversarial
review (two independent passes over the repo) confirmed that the *only*
foundational/operational dependency on the rich IdP (lldap + Authelia, both on
`messeldam`) is **step-ca's OIDC SSH-user-certificate provisioner.** Everything
else the foundation needs to be operated already works with the rich IdP down:

| Capability | Mechanism | Where | IdP-dependent? |
| --- | --- | --- | --- |
| OS login (human SSH, raw keys) | `keys.json` → `root` authorized_keys | `modules/common/openssh.nix` | **No** — verified: no host uses LDAP/PAM/nss/sssd for system login |
| SSH host identity | offline-signed host certs (731d), trusted via host CA | `lib/common/data/host-certs/` (17 hosts), `apps/ssh-host-cert-sign.nix` | **No** |
| TLS trust anchors | root + intermediate baked into system trust | `modules/common/internal-pki.nix` | **No** |
| TLS issuance (services) | step-ca **ACME** provisioner (unauthenticated) | `…/basel/modules/step-ca.nix` (`acme`) | **No** |
| Machine-to-machine mTLS | step-ca **X5C** provisioner, offline-signed enrollment certs | `modules/common/fluent-bit.nix`, `lib/common/data/fleet-x5c-certs/` | **No** |
| Secrets | sops + per-host age keys | `.sops.yaml`, host age key on disk | **No** |
| **SSH _user_ certs** | step-ca **OIDC "authelia"** provisioner → Authelia → lldap | `…/basel/modules/step-ca.nix` (`authelia`), `templates/oidc.tpl` | **Yes** ← the one coupling |

So the work is small and well-bounded: **sever that one coupling (Phase A),
harden the floor (Phase B), give the one non-foundational-but-incident-critical
consumer its own floor (Phase C, Perses)** — after which the rich IdP is free to
move up (Phase D, target-state).

### Important framing correction (current vs. target)

**There is no k3s cluster in the repo today.** k3s exists only as plans under
`llm-notes/plans/k3s-*.md`. Phases A–C below are **buildable now** against the
current microvm fleet and stand on their own merits (they remove a real
cold-boot fragility regardless of k3s — see the PKI appendix). Phase D is
**target-state design** contingent on the cluster existing and is labelled as
such. Do not read Phase D as a description of the current system.

---

## The two-criteria foundational test

The earlier "does the cluster depend on it?" test is necessary but not
sufficient. There are **two independent reasons** a service stays foundational:

1. **Dependency criterion** — the cluster / lower layers depend on it to
   function or be administered. → **PKI** (step-ca on `basel`), **DNS**
   (phantasma on `thebeyond`), **identity floor**.
2. **Failure-domain / incident-survivability criterion** — you need it to
   *survive and observe* an outage of the very thing it watches. →
   **observability + alerting** (VictoriaMetrics / VictoriaLogs / vmalert →
   Alertmanager → ntfy, and the Perses read surface) on `tharbad`.

PKI and DNS are foundational under (1). The observability stack is foundational
under (2) even though nothing *depends* on it. Both conclusions are the same:
**don't put these in the cluster they're meant to back or watch.** Only the
**rich identity** (lldap + Authelia) fails both tests and is therefore the thing
that moves up.

---

## Current state (grounded)

### step-ca (`basel`, microvm on calvard)

`hosts/calvard/microvm/guests/basel/modules/step-ca.nix`:

- Serves TLS directly on :443 (Go crypto/tls, no nginx). EC P-256 root +
  intermediate; intermediate key + password in sops; `badger` DB.
- **Holds both SSH CA private keys live** (`ssh.hostKey`, `ssh.userKey` from
  sops). Correction to an earlier finding: the SSH user CA is *not* offline —
  step-ca signs SSH user certs with it. The authoritative copies of the CA keys
  live in sops (and a `passage` store for the offline host-cert signer); `.keys/`
  is only transient bootstrap output.
- Provisioners:
  - `acme` — unauthenticated TLS for `*.internal` / `*.mutantmell.net`
    (45d default / 90d max). **No IdP dependency.**
  - `authelia` (OIDC, public client, `enableSSHCA = true`) — issues SSH **user**
    certs; principals come from the OIDC `groups` claim via
    `templates/oidc.tpl`. **The one foundational→IdP coupling.**
  - `fleet-x5c` (X5C, conditionally active when `fleet_x5c_ca.crt` is committed)
    — machine mTLS enrollment, 365d certs. Gated by offline-signed enrollment
    certs, **no IdP dependency.**
- **Principal authorization is enforced by the policy block**, not the
  provisioner: `policy.ssh.user.allow.principals = ["admin" "deploy"]`. This is
  load-bearing for Phase A.
- **Cold-boot circular dependency already exists and is worked around.**
  `step-ca-oidc-retry.service` handles the fact that step-ca must serve ACME
  before Authelia can present its (ACME-issued) TLS cert before step-ca can
  complete OIDC discovery. So the OIDC SSH path is fragile not only when the IdP
  is *down* but at *every cold boot* — independent motivation for Phase A.

### Human SSH floor

`modules/common/openssh.nix`: `PasswordAuthentication = false`,
`PermitRootLogin = "prohibit-password"`, operator public keys from
`lib/common/data/keys.json` deployed to `root`. Verified: **no host uses
LDAP/PAM/nss/sssd for system login**, so OS login survives a full IdP outage.
This is Ring 0 today.

### Rich IdP (lldap + Authelia, `messeldam`)

- Authelia → lldap over `ldap://127.0.0.1:3890`; cleanly separable.
- lldap durable state: SQLite at `/var/lib/private/lldap` (users / groups /
  password hashes; small, but exact size not repo-verifiable).
- `lldap-bootstrap` oneshot **declaratively seeds** the `admin`, `deploy`, and
  `media-users` groups plus the `authelia`/`jellyfin` bind users. The
  `admin`/`deploy` groups are exactly what feed SSH principals via the OIDC
  template — load-bearing.

### Other rich-IdP consumers (none foundational by criterion 1)

- **Perses** (tharbad, monitoring UI) → Authelia OIDC. Foundational by
  *criterion 2* (Phase C).
- **Jellyfin** (oracion) → lldap bind. Not foundational (media).
- **langport** oauth2-proxy still points at **old Keycloak**
  (`auth.mutantmell.net/realms/homelab`), and is currently commented out —
  migration mid-flight. Not foundational.

---

## Target state (aspirational — contingent on k3s)

Once Phases A–C are done, the rich IdP can move up:

- **lldap + Authelia → tier-2 cluster workloads** (KubeVirt VM or Pod+PVC), with
  lldap's durable state on CSI + VolumeSnapshot. They are already separable.
- **The cluster gets its own Ring-0 floor**: the on-disk x509 **k3s admin
  kubeconfig** (no OIDC). This is the analogue of the SSH raw-key floor, one
  layer up. **Hard requirement:** it must be provably **OIDC-free and
  DNS-independent** (IP-addressable API server), and tested — otherwise moving
  the IdP into the cluster creates a cold-boot circular dependency
  (kubectl-via-OIDC can't authenticate to fix the cluster whose IdP pods are
  down). This decision is owned jointly with
  `k3s-cluster-bootstrap-plan.md` open decision #1.
- **DNS / firewall re-pointing**: consumers resolve the IdP via
  `authelia.internal.mutantmell.net` / `ldap.internal` (phantasma). Moving up =
  re-point DNS + convert the messeldam-targeted rules into router6 `cluster`
  zone rules (the cluster zone the bootstrap plan introduces).

What **stays foundational regardless**: PKI (`basel`), DNS (phantasma on
`thebeyond`), and the **whole observability stack** on `tharbad` (Perses
included — see the two-criteria test).

---

## The three-ring operator-access model

| Ring | Credential | Proves | Available when IdP/cluster is… |
| --- | --- | --- | --- |
| 0 | raw SSH key (`keys.json`) | static, not identity-bound | always |
| 1 | **foundational step-ca JWK SSH cert** (Phase A) | "an authorized operator" — real cert, `admin` principal | always (cluster-independent) |
| 2 | OIDC → Authelia SSH cert | *you*, as a directory user in `admin` (audited, per-user) | only when the IdP is up |

Per-user, directory-backed identity (Ring 2) is inherently only as available as
the directory — if the directory moves into the cluster, Ring 2 is only as
available as the cluster. That is *by design*: Ring 1 is the cluster-independent
credentialed path that keeps "cluster down" from meaning "raw break-glass," and
Ring 0 stays the rare cold path. (SSH user certs are short-lived ~1h, so a
cached cert is not a fallback during an outage — the *issuer* needs a
cluster-independent path, which is what Phase A provides.)

---

## Phase A — foundational JWK SSH-user-cert provisioner (the main work)

**Goal:** operator SSH cert login works with Authelia/lldap (and, later, the
cluster) **down**, via a provisioner gated by an offline secret rather than
OIDC. This is buildable today and is the single highest-value change.

Add a **JWK** provisioner to `step-ca.nix` (alongside the existing `acme`,
`authelia`, `fleet-x5c`):

- **JWK, not X5C.** step-ca already holds the SSH user CA key (`ssh.userKey`),
  so this is purely a provisioner addition — no new CA, no new key material.
  Use a dedicated JWK keypair whose password is held offline (sops + operator
  vault). **Do not reuse the `fleet-x5c` CA for human admin** — that would
  conflate the machine and human trust domains; keep them separate.
- `claims.enableSSHCA = true` so it can issue SSH **user** certs (confirmed
  supported by step-ca; JWK can issue SSH user certs without OIDC).
- **Pin the principal in a per-provisioner SSH template.** This is the critical
  detail: with JWK the requester can pass `--principal`, and the default
  principal is the token subject — there is no `groups` claim to constrain it.
  Safety must not rest solely on the existing
  `policy.ssh.user.allow.principals = ["admin" "deploy"]` allowlist. Ship a
  template (sibling to `templates/oidc.tpl`) that **hard-codes** the emitted
  principal(s) to `admin` rather than trusting requester input. The policy
  allowlist remains as defense-in-depth, but the template is the primary gate.
- **No renewal via JWK** — JWK can't renew/rekey SSH certs (would need a
  companion SSHPOP provisioner). For ~1h break-glass certs this is fine:
  re-issue, don't renew. State this in the runbook.

Keep the `authelia` OIDC provisioner as the **daily convenience / SSO path**
(per-user, audited, group-derived principals). `ssh-cert-client.nix` keeps
`provisioner = "authelia"` as the default; document the JWK provisioner as the
cluster-independent path (`step ssh login --provisioner <jwk-name>` /
`step ssh certificate`).

**Optional stronger posture (recommended, decide in open decisions):** make the
JWK provisioner the *routine* path for tier-1 host SSH and reserve OIDC for
cluster/app SSO + `kubectl`. Then routine SSH to foundational hosts never
depends on the cluster at all, up or down.

**Validation:**

- With Authelia stopped on messeldam, `step ssh certificate admin …` against the
  JWK provisioner issues a cert with `Principals: admin`, and SSH into
  `calvard`/`liberl`/`thebeyond` succeeds.
- A request attempting `--principal root` (or anything outside `admin`/`deploy`)
  is rejected by the template/policy.
- The existing OIDC path still works when Authelia is up.

---

## Phase B — break-glass hardening (optional)

Today the daily keys (`deploy`/`home`/`edith` in `keys.json`) *are* Ring 0 —
the floor already exists. Optionally add a **dedicated break-glass key** to
`root`'s authorized_keys on the foundational hosts whose private half lives
offline (not on the daily workstation), so a cold path survives even
workstation/cluster compromise. Small change; sequencing-independent of Phase A.

---

## Phase C — Perses break-glass auth (decouple monitoring from the rich IdP)

**Why:** Perses (tharbad) is foundational by criterion 2 but today authenticates
**OIDC-only** to Authelia, and **fatally exits at startup** if it can't reach
Authelia (there is already systemd retry hardening for this in `perses.nix`). So
a "foundational" Perses whose login depends on a cluster-hosted IdP is not
*really* foundational. "Existing sessions degrade gracefully" is **not**
reliable — tokens are short (15m/24h) and a Perses restart during an outage
locks you out entirely.

**Fix (as-code, fits the dashboards-as-code ethos):** in
`hosts/calvard/microvm/guests/tharbad/modules/perses.nix`:

1. Enable the **native provider** and provision a local break-glass admin
   as-code:
   ```nix
   authentication.providers = {
     enable_native = true;
     disable_sign_up = true;   # native login allowed; no self-service accounts
     oidc = [ { ...existing Authelia block... } ];
   };
   ```
   Add a provisioned `User` resource (mirroring how the existing `adminRole` /
   `adminBinding` are built and added to the provisioning folder) with
   `spec.nativeProvider.password` sourced from a new `perses-admin-password`
   sops secret, and bind it into the admin `GlobalRoleBinding`. Provisioned
   resources are re-applied every boot, so the account can't drift or be deleted
   via the UI.
2. **Keep in-app OIDC** as the daily path. Do **not** switch to nginx
   `auth_request` — proxy auth wouldn't remove the IdP dependency and would lose
   Perses's native RBAC subject mapping. The current pass-through nginx is
   correct.
3. **Optional:** anonymous read-only on the management VLAN — a low-privilege
   role + `guest_permissions`/anonymous binding so dashboards are *viewable*
   with no login during an incident, while writes still require auth. Gate by
   network (Perses listens on `127.0.0.1` behind nginx on `perses.internal`).

**Implementation caveat to validate at build time (not hand-wave):** confirm the
running Perses version accepts `_secret` indirection *inside* a provisioned
`User` resource (the module already does this for `client_secret` /
`encryption_key`). If `_secret` isn't supported inside provisioned files, render
the `User` YAML via the systemd `LoadCredential` / pre-start substitution path
instead. Also re-check whether the "fatal exit if OIDC unreachable at startup"
behavior persists once a native provider is also configured; if native presence
makes startup tolerant of a down OIDC, the retry hardening can relax.

This makes Perses survive a cluster/IdP outage in both compute (stays on
tharbad) and auth (native floor) — so moving the rich IdP up no longer degrades
observability.

---

## Phase D — move the rich IdP up (target-state, contingent on k3s)

Only after A–C. Per "Target state" above: relocate lldap + Authelia to the
cluster (state on CSI + VolumeSnapshot), establish the cluster's x509
admin-kubeconfig floor (OIDC-free, DNS-independent, tested), re-point DNS, and
convert messeldam-targeted firewall rules into router6 `cluster`-zone rules.
This phase is owned jointly with `k3s-cluster-bootstrap-plan.md`.

A softer interim variant: keep lldap + Authelia on a microvm but *reclassify*
the dependency posture (same host, no longer treated as foundational) once A–C
guarantee nothing foundational depends on them. This captures most of the
decoupling benefit without requiring the cluster.

---

## Classification summary

| Service | Foundational? | Criterion | Disposition |
| --- | --- | --- | --- |
| PKI — step-ca (`basel`) | Yes | dependency | stays; add JWK provisioner (Phase A) |
| DNS — phantasma (`thebeyond`) | Yes | dependency | stays |
| Observability stack (`tharbad`, incl. Perses) | Yes | failure-domain | stays; add native floor (Phase C) |
| Human SSH floor (`keys.json`, host certs) | Yes | — (already declarative) | stays |
| Machine mTLS (fleet X5C) | Yes | — (already IdP-independent) | stays |
| **lldap + Authelia (rich identity)** | **No** | fails both | **moves up** (Phase D) |
| Jellyfin / langport oauth2-proxy | No | — | follow the IdP wherever it lands |

---

## Open decisions

1. **Routine tier-1 SSH path.** Make the Phase-A JWK provisioner the *routine*
   path for foundational-host SSH (recommended — fully roots tier-1 ops in
   tier ≤ 1), or keep OIDC as routine and JWK as break-glass only?
2. **Cluster admin-kubeconfig floor (Phase D).** Exact mechanism guaranteeing it
   is OIDC-free and DNS-independent (IP-addressable API server); how it's stored
   and tested. Shared with `k3s-cluster-bootstrap-plan.md` open decision #1.
3. **Where lldap state lands (Phase D).** CSI-backed PVC in-cluster vs.
   microvm-with-reclassified-posture (the softer interim).
4. **Perses anonymous read (Phase C).** Enable management-VLAN anonymous
   read-only, or native-admin + OIDC only?
5. **Fleet mTLS cert lifetime** (see appendix) — shorten from 365d, or add
   revocation?

---

## Appendix: PKI hygiene (surfaced during review, fold into the work)

These are pre-existing concerns independent of the decoupling, worth fixing
while touching step-ca:

- **Root + intermediate expire in 2032** (issued 2022) — already ~4 years aged,
  not "10 years fresh." A homelab root expiring takes down *all* internal TLS at
  once. Schedule rotation / re-issue well before 2032; document the procedure.
- **No CRL/OCSP.** Revocation relies on short cert lifetimes. Fine for ~1h SSH
  user certs and 45–90d ACME certs, but **365d fleet mTLS certs** (and the
  ~5-year X5C enrollment certs) have **no revocation path** — a compromised
  fleet host's client cert is valid for up to a year. Shorten the fleet mTLS
  lifetime or add a revocation mechanism (open decision #5).
- **badger DB** is single-process and corruption-prone on disk-full; smallstep
  recommends `badgerv2` or a SQL backend for anything load-bearing. step-ca is
  foundational here, so note it / consider migrating.
- **Boot-ordering dependencies** that must be preserved if services move:
  - sops/age: every secret (incl. step-ca's CA keys and Authelia's) decrypts via
    the host age key on disk. Moving services up changes secret delivery —
    preserve the age-key provisioning order or the whole chain fails to decrypt.
  - DNS-before-TLS: step-ca, fleet mTLS, and ACME all resolve `*.internal` via
    phantasma *before* TLS. This deepens cold-boot ordering and is why DNS stays
    foundational.
  - The step-ca↔Authelia cold-boot circular dependency
    (`step-ca-oidc-retry.service`) is real today; Phase A's non-OIDC path
    reduces its blast radius (operator access no longer waits on that retry
    loop).

---

## Why each phase stands alone

- **Phase A** removes a real cold-boot fragility (operator cert access currently
  waits on the OIDC retry loop) — valuable even if k3s never happens.
- **Phase B** is pure hardening.
- **Phase C** makes monitoring survive *any* IdP outage — valuable today (a
  messeldam reboot currently knocks out Perses login).
- **Phase D** is the only cluster-contingent phase, and it's the one this whole
  plan exists to make safe.
