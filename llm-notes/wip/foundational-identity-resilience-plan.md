# Foundational Identity Resilience Plan

Status: In progress — Phase A COMPLETE (2026-06-05); Phases B, C NOT STARTED

Date: 2026-06-04

> Reframed 2026-06-04 from an earlier "decoupling so the IdP can move up"
> draft. **The rich IdP (lldap + Authelia) stays foundational** — moving it
> into the planned k3s cluster has been considered and rejected (see "Rejected:
> moving the IdP into the cluster"). The valuable, buildable content (Phases
> A–C) is pure resilience and never required the move.

## What this is

Make the homelab's **foundational operator access** (SSH; monitoring)
**resilient to an outage of the rich identity provider** (lldap + Authelia on
`messeldam`). The rich IdP **stays foundational**; this plan adds _break-glass_
paths beneath the services that currently route through it, so that when
Authelia/lldap are down — or merely cold-booting — operators can still obtain
SSH certificates and read dashboards.

Driving principle: **operational access to a layer must not hinge on a single
service that can be unavailable exactly when you need access most.** The rich
IdP is a single point of failure that step-ca's SSH-cert path and Perses login
currently sit on top of; this plan adds IdP-independent fallbacks underneath
them.

## Relationship to other plans

- **Informs** `llm-notes/plans/k3s-cluster-bootstrap-plan.md` (identity
  open-decision): the cluster's `kubectl` OIDC can point at the **foundational**
  Authelia — tier-2 → tier-1, the correct dependency direction, **no circular
  dependency** — with the on-disk x509 admin kubeconfig as the cluster's own
  break-glass. The bootstrap plan cross-references this document.
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
review (two independent passes over the repo) confirmed that the _only_
foundational/operational dependency on the rich IdP (lldap + Authelia, both on
`messeldam`) is **step-ca's OIDC SSH-user-certificate provisioner.** Everything
else the foundation needs to be operated already works with the rich IdP down:

| Capability                     | Mechanism                                                    | Where                                                                   | IdP-dependent?                                                     |
| ------------------------------ | ------------------------------------------------------------ | ----------------------------------------------------------------------- | ------------------------------------------------------------------ |
| OS login (human SSH, raw keys) | `keys.json` → `root` authorized_keys                         | `modules/common/openssh.nix`                                            | **No** — verified: no host uses LDAP/PAM/nss/sssd for system login |
| SSH host identity              | offline-signed host certs (731d), trusted via host CA        | `lib/common/data/host-certs/` (17 hosts), `apps/ssh-host-cert-sign.nix` | **No**                                                             |
| TLS trust anchors              | root + intermediate baked into system trust                  | `modules/common/internal-pki.nix`                                       | **No**                                                             |
| TLS issuance (services)        | step-ca **ACME** provisioner (unauthenticated)               | `…/basel/modules/step-ca.nix` (`acme`)                                  | **No**                                                             |
| Machine-to-machine mTLS        | step-ca **X5C** provisioner, offline-signed enrollment certs | `modules/common/fluent-bit.nix`, `lib/common/data/fleet-x5c-certs/`     | **No**                                                             |
| Secrets                        | sops + per-host age keys                                     | `.sops.yaml`, host age key on disk                                      | **No**                                                             |
| **SSH _user_ certs**           | step-ca **OIDC "authelia"** provisioner → Authelia → lldap   | `…/basel/modules/step-ca.nix` (`authelia`), `templates/oidc.tpl`        | **Yes** ← the one coupling                                         |

So the work is small and well-bounded: **add an IdP-independent SSH-cert path
(Phase A), harden the floor (Phase B), and give Perses its own login floor
(Phase C).** All three are resilience measures against the rich IdP being
unavailable; **none requires relocating it.**

### Framing: current state only (no cluster yet)

**There is no k3s cluster in the repo today** — k3s exists only as plans under
`llm-notes/plans/k3s-*.md`. Phases A–C are **buildable now** against the current
microvm fleet and stand on their own merits: they remove a **real, present-day
fragility** — the step-ca↔Authelia cold-boot circular dependency, and Perses
fatally exiting without Authelia. Nothing in this plan is contingent on k3s.

---

## The two-criteria foundational test (and where the rich IdP lands)

There are **two independent reasons** a service stays foundational:

1. **Dependency criterion** — the cluster / lower layers depend on it to
   function or be administered. → **PKI** (step-ca on `basel`), **DNS**
   (phantasma on `thebeyond`), and **the rich IdP** (see below).
2. **Failure-domain / incident-survivability criterion** — you need it to
   _survive and observe_ an outage of the very thing it watches. →
   **observability + alerting** (VictoriaMetrics / VictoriaLogs / vmalert →
   Alertmanager → ntfy, and the Perses read surface) on `tharbad`.

**Where the rich IdP lands: foundational, by criterion 1.** step-ca's
SSH-user-cert path depends on Authelia today, and the planned cluster's
`kubectl` OIDC would too. A thing the control plane _and_ the cluster both
depend on belongs **below** them, not inside the cluster. (This corrects an
earlier draft that scored the IdP "fails both tests → moves up" — it actually
_satisfies_ criterion 1.) So the rich IdP **stays a foundational microvm**,
matching `llm-notes/reports/k8s-migration-evaluation.md`'s settled decision
(_"auth … → microvm.nix; per-service failure domain matters; Authelia stays in
its own microvm"_). What this plan changes is **resilience**, not placement.

---

## Current state (grounded)

### step-ca (`basel`, microvm on calvard)

`hosts/calvard/microvm/guests/basel/modules/step-ca.nix`:

- Serves TLS directly on :443 (Go crypto/tls, no nginx). EC P-256 root +
  intermediate; intermediate key + password in sops; `badger` DB.
- **Holds both SSH CA private keys live** (`ssh.hostKey`, `ssh.userKey` from
  sops). Correction to an earlier finding: the SSH user CA is _not_ offline —
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
  is _down_ but at _every cold boot_ — the core motivation for Phase A.

### Human SSH floor

`modules/common/openssh.nix`: `PasswordAuthentication = false`,
`PermitRootLogin = "prohibit-password"`, operator public keys from
`lib/common/data/keys.json` deployed to `root`. Verified: **no host uses
LDAP/PAM/nss/sssd for system login**, so OS login survives a full IdP outage.
This is Ring 0 today.

### Rich IdP (lldap + Authelia, `messeldam`)

- Authelia → lldap over `ldap://127.0.0.1:3890`.
- lldap durable state: SQLite at `/var/lib/private/lldap` (users / groups /
  password hashes; small, but exact size not repo-verifiable).
- `lldap-bootstrap` oneshot **declaratively seeds** the `admin`, `deploy`, and
  `media-users` groups plus the `authelia`/`jellyfin` bind users. The
  `admin`/`deploy` groups are exactly what feed SSH principals via the OIDC
  template — load-bearing.

### Other rich-IdP consumers

- **Perses** (tharbad, monitoring UI) → Authelia OIDC. Foundational by
  _criterion 2_ (Phase C).
- **Jellyfin** (oracion) → lldap bind. Not foundational (media).
- **langport** — its oauth2-proxy reverse-proxy stack was **removed entirely**
  (authelia-migration Phase 2e, 2026-06-05), not migrated; external ingress for
  `mutantmell.net`/`auth.mutantmell.net` is a deferred cloud-host workstream.
  Nothing here is foundational.

---

## Rejected: moving the IdP into the cluster

An earlier draft of this plan proposed relocating lldap + Authelia "up" into the
k3s cluster as tier-2 workloads. **Rejected.** Reasons:

- **It would create a dependency loop.** The cluster's `kubectl` OIDC (and
  step-ca's SSH path) depend on the IdP. Putting the IdP _inside_ the cluster
  means cluster-down ⇒ can't authenticate to fix the cluster, which then
  requires a carefully-guaranteed OIDC-free admin-kubeconfig to _break_ the loop.
  Keeping the IdP foundational means the cluster simply depends on a lower tier
  (correct direction) with **no loop to engineer around in the first place.**
- **Per-service failure domain is stronger on a microvm** than as a cluster pod
  sharing the cluster's failure domain.
- **It already works and is already as-code.** Authelia OIDC clients and lldap
  groups are declarative (NixOS modules + `lldap-bootstrap` + sops). Moving to
  the cluster buys nothing on the "infrastructure-as-text" axis.
- **It contradicts the settled design.**
  `llm-notes/reports/k8s-migration-evaluation.md` classifies auth as a
  foundational microvm service that explicitly does _not_ migrate.

The cluster still benefits without the move: its `kubectl` OIDC points at the
foundational Authelia (tier-2 → tier-1), and it keeps the standard on-disk x509
admin kubeconfig as its _own_ break-glass — a k3s-bootstrap concern, owned by
`k3s-cluster-bootstrap-plan.md`, not this plan. Nothing about the cluster
requires the IdP to live inside it.

---

## The three-ring operator-access model

| Ring | Credential                                      | Proves                                                    | Available when the rich IdP is… |
| ---- | ----------------------------------------------- | --------------------------------------------------------- | ------------------------------- |
| 0    | raw SSH key (`keys.json`)                       | static, not identity-bound                                | always                          |
| 1    | **foundational step-ca JWK SSH cert** (Phase A) | "an authorized operator" — real cert, `admin` principal   | always (IdP-independent)        |
| 2    | OIDC → Authelia SSH cert                        | _you_, as a directory user in `admin` (audited, per-user) | only when Authelia is up        |

Ring 2 (per-user directory identity) is only ever as available as the directory
— that's inherent. Ring 1 is the IdP-independent credentialed path that keeps
"Authelia down / cold-booting" from forcing a fall to raw break-glass; Ring 0
stays the rare cold path. (SSH user certs are short-lived ~1h, so a cached cert
is _not_ a fallback during an outage — the _issuer_ needs an IdP-independent
path, which is exactly what Phase A provides.)

---

## Phase A — foundational JWK SSH-user-cert provisioner (the main work) — COMPLETE

> **COMPLETE (2026-06-05).** Shipped the `admin-jwk` JWK provisioner on
> `basel` (`hosts/calvard/microvm/guests/basel/modules/step-ca.nix`) with a
> principal-pinning template (`templates/admin-jwk.tpl` → `["admin"]`) and key
> material in `lib/common/data/pki/` (`adminJwk` in
> `lib/common/data/default.nix`). **Validated live:** break-glass issuance
> against the running CA succeeds, emits an `admin`-principal cert, and works
> with Authelia stopped on messeldam. Operator runbook:
> [`guides/step-ca-jwk-break-glass.md`](../guides/step-ca-jwk-break-glass.md).
> Design sketch below retained for reference.

**Goal:** operator SSH cert login works with Authelia/lldap **down** (or
cold-booting), via a provisioner gated by an offline secret rather than OIDC.
Buildable today; the single highest-value change.

Add a **JWK** provisioner to `step-ca.nix` alongside the existing `acme`,
`authelia`, `fleet-x5c`:

- **Two distinct keys — don't conflate them.** A JWK provisioner has its **own
  JWK auth keypair** (the provisioner credential that _authorizes_ a request,
  encrypted under an offline password). That is **separate** from the **SSH user
  CA** (`ssh.userKey`) that _signs_ the issued certificate. So: **you do add new
  key material — the JWK provisioner keypair — but you do _not_ add a new signing
  CA;** step-ca reuses its existing SSH user CA to sign. (This corrects an
  earlier draft that said "no new key material.") Hold the JWK password offline
  (sops + operator vault). **Do not reuse the `fleet-x5c` CA for human admin** —
  keep the machine and human trust domains separate.
- `claims.enableSSHCA = true` so it can issue SSH **user** certs (step-ca
  supports SSH user certs from a JWK provisioner, not only via OIDC).
- **Pin the principal in a per-provisioner SSH template.** This is the critical
  detail: with JWK the requester can pass `--principal`, and the default
  principal is the token subject — there is no `groups` claim to constrain it.
  Safety must **not** rest solely on the existing
  `policy.ssh.user.allow.principals = ["admin" "deploy"]` allowlist. Ship a
  template (sibling to `templates/oidc.tpl`) that **hard-codes** the emitted
  principal(s) to `admin` rather than trusting requester input. The policy
  allowlist remains as defense-in-depth; the template is the primary gate.
- **No renewal via JWK** — JWK can't renew/rekey SSH certs (would need a
  companion SSHPOP provisioner). For ~1h break-glass certs this is fine:
  re-issue, don't renew. State this in the runbook.

Keep the `authelia` OIDC provisioner as the **daily convenience / SSO path**
(per-user, audited, group-derived principals). `ssh-cert-client.nix` keeps
`provisioner = "authelia"` as the default; the JWK provisioner is documented as
the IdP-independent path in
[`guides/step-ca-jwk-break-glass.md`](../guides/step-ca-jwk-break-glass.md)
(operator runbook — issue, no-renewal, key rotation, validation).

**Optional stronger posture (recommended, decide in open decisions):** make the
JWK provisioner the _routine_ path for tier-1 host SSH and reserve OIDC for
cluster/app SSO + `kubectl`. Then routine SSH to foundational hosts never
depends on the rich IdP at all, up or down.

**Validation:**

- With Authelia stopped on messeldam, `step ssh certificate admin …` against the
  JWK provisioner issues a cert with `Principals: admin`, and SSH into
  `calvard`/`liberl`/`thebeyond` succeeds.
- A request attempting `--principal root` (or anything outside `admin`/`deploy`)
  is rejected by the template/policy.
- The existing OIDC path still works when Authelia is up.

---

## Phase B — break-glass hardening (optional) — NOT STARTED

Today the daily keys (`deploy`/`home`/`edith` in `keys.json`) _are_ Ring 0 —
the floor already exists. Optionally add a **dedicated break-glass key** to
`root`'s authorized_keys on the foundational hosts whose private half lives
offline (not on the daily workstation), so a cold path survives even
workstation compromise. Small change; sequencing-independent of Phase A.

---

## Phase C — Perses login floor (resilience for monitoring) — NOT STARTED

**Why:** Perses (tharbad) is foundational by criterion 2 but today authenticates
**OIDC-only** to Authelia, and **fatally exits at startup** if it can't reach
Authelia (there is already systemd retry hardening for this in `perses.nix`). So
a "foundational" monitoring surface whose login routes through the same IdP that
might be down is not _really_ resilient. "Existing sessions degrade gracefully"
is **not** reliable — tokens are short (15m/24h) and a Perses restart during an
outage locks you out entirely.

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
   role + `guest_permissions`/anonymous binding so dashboards are _viewable_
   with no login during an incident, while writes still require auth. Gate by
   network (Perses listens on `127.0.0.1` behind nginx on `perses.internal`).

**Implementation caveat to validate at build time (not hand-wave):** confirm the
running Perses version accepts `_secret` indirection _inside_ a provisioned
`User` resource (the module already does this for `client_secret` /
`encryption_key`). If `_secret` isn't supported inside provisioned files, render
the `User` YAML via the systemd `LoadCredential` / pre-start substitution path
instead. Also re-check whether the "fatal exit if OIDC unreachable at startup"
behavior persists once a native provider is also configured; if native presence
makes startup tolerant of a down OIDC, the retry hardening can relax.

This makes Perses survive an Authelia/messeldam outage in both compute (it stays
on tharbad) and auth (native floor) — so an IdP outage no longer takes out
monitoring login.

---

## Classification summary

| Service                                       | Foundational? | Criterion                                                             | Disposition                                                         |
| --------------------------------------------- | ------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------- |
| PKI — step-ca (`basel`)                       | Yes           | dependency                                                            | stays; add JWK provisioner (Phase A)                                |
| DNS — phantasma (`thebeyond`)                 | Yes           | dependency                                                            | stays                                                               |
| Observability stack (`tharbad`, incl. Perses) | Yes           | failure-domain                                                        | stays; add native login floor (Phase C)                             |
| Human SSH floor (`keys.json`, host certs)     | Yes           | — (already declarative)                                               | stays                                                               |
| Machine mTLS (fleet X5C)                      | Yes           | — (already IdP-independent)                                           | stays                                                               |
| **lldap + Authelia (rich identity)**          | **Yes**       | **dependency** (step-ca SSH + planned cluster `kubectl` depend on it) | **stays foundational; add IdP-independent fallbacks (Phases A, C)** |
| Jellyfin (lldap bind)                         | No            | —                                                                     | unchanged (langport oauth2-proxy removed, Phase 2e)                 |

---

## Open decisions

1. **Routine tier-1 SSH path.** Make the Phase-A JWK provisioner the _routine_
   path for foundational-host SSH (recommended — fully roots tier-1 ops in a
   layer at or below the host), or keep OIDC as routine and JWK as break-glass
   only?
2. **Perses anonymous read (Phase C).** Enable management-VLAN anonymous
   read-only, or native-admin + OIDC only?
3. **Fleet mTLS cert lifetime** (see appendix) — shorten from 365d, or add
   revocation?

---

## Appendix: PKI hygiene (surfaced during review, fold into the work)

Pre-existing concerns independent of the resilience work, worth fixing while
touching step-ca:

- **Root + intermediate expire in 2032** (issued 2022) — already ~4 years aged,
  not "10 years fresh." A homelab root expiring takes down _all_ internal TLS at
  once. Schedule rotation / re-issue well before 2032; document the procedure.
- **No CRL/OCSP.** Revocation relies on short cert lifetimes. Fine for ~1h SSH
  user certs and 45–90d ACME certs, but **365d fleet mTLS certs** (and the
  ~5-year X5C enrollment certs) have **no revocation path** — a compromised
  fleet host's client cert is valid for up to a year. Shorten the fleet mTLS
  lifetime or add a revocation mechanism (open decision #3).
- **badger DB** is single-process and corruption-prone on disk-full; smallstep
  recommends `badgerv2` or a SQL backend for anything load-bearing. step-ca is
  foundational here, so note it / consider migrating.
- **Boot-ordering facts** worth keeping in view:
  - sops/age: every secret (incl. step-ca's CA keys and Authelia's) decrypts via
    the host age key on disk.
  - DNS-before-TLS: step-ca, fleet mTLS, and ACME all resolve `*.internal` via
    phantasma _before_ TLS — one reason DNS stays foundational.
  - The step-ca↔Authelia cold-boot circular dependency
    (`step-ca-oidc-retry.service`) is real today; Phase A's non-OIDC path
    reduces its blast radius (operator SSH access no longer waits on that retry
    loop).

---

## Why each phase stands alone

- **Phase A** removes a real, present-day fragility — operator cert access
  currently waits on the step-ca OIDC retry loop and fails when Authelia is down
  or cold-booting. Valuable independent of k3s.
- **Phase B** is pure hardening.
- **Phase C** makes monitoring login survive an IdP outage — valuable today (a
  messeldam reboot currently knocks out Perses login).
