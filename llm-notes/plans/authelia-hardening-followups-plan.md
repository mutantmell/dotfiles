# Authelia Hardening Follow-ups

Status: Planned (not started)

Date: 2026-06-05

> Extracted from the follow-up section of
> [`authelia-migration-plan.md`](../wip/authelia-migration-plan.md) when the
> Keycloak→Authelia migration's core work completed (Keycloak removed, Phase 3).
> These items are **orthogonal to the migration** — they're AuthN/AuthZ
> hardening that Authelia makes easier, not migration steps — so they live in
> their own plan rather than holding the migration open. Each is independent and
> can be done in any order.

These were follow-ups **F1, F2, F4, F5** in the migration plan. **F3** (rewrite
the headscale plan's Keycloak references to Authelia) was handled inline during
the migration's Phase 4 doc cleanup — `headscale-integration-plan.md` now carries
a Keycloak→Authelia translation table at the top.

## Related plans

- [`foundational-identity-resilience-plan.md`](../shelved/foundational-identity-resilience-plan.md)
  — IdP **availability** (break-glass SSH/monitoring when Authelia/lldap are
  down). Distinct axis from this plan, which is about AuthN **strength**, audit,
  and incident response. The two intersect on revocation (see F4 vs. that plan's
  PKI-hygiene appendix, which covers _certificate_ revocation; F4 here is _OIDC
  session/account_ revocation).
- [`headscale-integration-plan.md`](./headscale-integration-plan.md) — its threat
  model (friend credential compromise) is a primary driver for F1/F2/F4. MFA for
  admins and an audit trail matter more once friends are on the network.
- [`../reports/friend-access-schemes.md`](../reports/friend-access-schemes.md) —
  the threat model these harden against.

---

## F1 — MFA enrollment for admin accounts

**The single biggest remaining AuthN gap.** Admin accounts that reach
infrastructure UIs (Perses, step-ca SSH login, lldap web UI, future
auth_request-protected services) authenticate with a single factor today.
Authelia supports TOTP and WebAuthn natively with a self-service enrollment
portal.

Work:

- Flip admin-scoped access-control rules in `authelia.nix` from `one_factor` to
  `two_factor`. **Caveat:** there are **no auth_request-protected domains today**
  (the `access_control.rules` block only has the portal `bypass` rule); the first
  protected domain arrives with the deferred external-ingress workstream. So the
  `two_factor` policy has nothing to gate _yet_ — F1 is most actionable once
  either (a) external ingress lands, or (b) an internal service is put behind
  Authelia `auth_request`.
- Decide MFA enforcement for the **OIDC consumers**: step-ca SSH login and Perses
  both use `authorization_policy: one_factor` on their clients. Raising these to
  `two_factor` forces MFA at the IdP for every SSH-cert issuance / Perses login —
  evaluate the friction (every `step ssh login` would require a second factor)
  against the value. This is the higher-impact lever since these clients _exist_
  today, unlike access-control domains.
- Complete TOTP or WebAuthn enrollment for each admin user via the Authelia
  portal. Enrollment state lives in the `authelia-main` SQLite (already
  persisted) — no new persistence.
- WebAuthn requires a `webauthn` config block (RP id/display name) in
  `authelia.nix`; TOTP works with defaults.

Cross-reference: the headscale plan already assumes `admins: Required (WebAuthn
or TOTP)` — F1 is the prerequisite that makes that real.

## F2 — Auth audit trail via central logging

**Largely already handled — verify and add a view, don't rebuild.** Authelia
logs auth events (successes, failures, MFA challenges) as JSON to stdout
(`log.format = "json"` is set in `authelia.nix`), and messeldam runs
`fluent-bit-agent.enable = true`, whose **systemd-journal input already ships
the journal to VictoriaLogs** at tharbad. So Authelia auth events are **already
centralized today** — the data is queryable in VictoriaLogs (`SYSTEMD_UNIT =
authelia-main.service`).

Residual work (small):

- Add a saved query / Perses (VictoriaLogs datasource) dashboard panel for
  "auth events by user/result over time" so the audit trail is _usable_, not
  just _captured_. The dashboards-as-code pattern on tharbad
  (`tharbad/modules/dashboards`) is the home for this.
- Optionally set an explicit `log.file_path` only if a separate audit stream
  (distinct retention) is wanted; not needed for basic centralization.

This becomes operationally valuable once friends are on the network (headscale)
and "who accessed what, when" has real incident-response weight.

## F4 — Token revocation & incident-response runbook

**DONE — drafted as [`guides/authelia-incident-response.md`](../guides/authelia-incident-response.md)
(2026-06-05).** Companion to the break-glass runbook
[`guides/step-ca-jwk-break-glass.md`](../guides/step-ca-jwk-break-glass.md).
The runbook covers everything below; the validate-on-first-use caveat is that
the SQLite session-table delete (§2) needs the pinned Authelia version's schema
confirmed before running. Original F4 outline retained for reference:

There is no documented procedure for "a user's OIDC session or account is
compromised — what now?" Authelia supports session revocation and short token
lifetimes limit the window, but the steps aren't written down.

Write a runbook (a `guides/` entry once drafted) covering:

- **Revoke a user's active sessions** — delete from the `authelia-main` SQLite
  session store (document the table/command for the pinned Authelia version).
- **Disable an account** — remove the user from `media-users`/`admin` or delete
  it in the lldap web UI (`ldap.internal`); Authelia binds lldap on each request,
  so the change takes effect at next auth. Document the propagation timing.
- **Rotate OIDC signing keys** — replace `authelia-oidc-issuer-private-key` in
  sops + redeploy; forces all issued tokens to re-validate. Note the blast
  radius (every consumer re-auths).
- **For headscale (future)** — revoke a friend's node identity (cross-link the
  headscale plan's revocation section).

Note the overlap with the resilience plan's PKI-hygiene appendix: that covers
**certificate** revocation (no CRL/OCSP; relies on short lifetimes for SSH/ACME/
fleet-mTLS certs). This F4 item is the **OIDC session/account** half. Keep both
in view when writing the runbook so it's coherent end to end.

## F5 — Conscious decision: no mTLS for internal service communication

**This is a recorded decision, not future work.** Internal services (Prometheus
scraping, VictoriaLogs ingestion, step-ca ACME) authenticate via TLS _server_
certificates but not mutual TLS — any host on the same VLAN can reach them, and
the **zone firewall (router nftables) is the primary access control**.

This is an accepted tradeoff for a homelab: per-service mTLS (client-cert
provisioning, rotation, trust-store management) adds significant complexity for
marginal gain when VLAN boundaries are already enforced. Documenting it as a
**conscious decision** rather than an oversight.

Revisit only if the threat model changes — e.g. multi-tenant VLANs or untrusted
workloads co-located with infrastructure services on the same zone. The step-ca
X5C/fleet-mTLS machinery to support it already exists (it's used today for the
fluent-bit fleet agents), so the cost to introduce mTLS later is bounded.

(Note: this is partially _already_ contradicted-in-a-good-way by the fleet
fluent-bit agents, which **do** use X5C-issued client certs to push logs/metrics
— so the "no mTLS" posture is specifically about the _scrape/ingest server_
side and inter-service calls that don't already have it, not an absolute.)
