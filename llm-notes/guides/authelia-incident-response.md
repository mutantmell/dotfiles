# Authelia / lldap incident response & revocation

**Status:** operator-facing runbook. Implements follow-up **F4** from
[`authelia-hardening-followups-plan.md`](../plans/authelia-hardening-followups-plan.md).
Covers the **OIDC session / account** half of revocation; the **certificate**
half (no CRL/OCSP; short lifetimes) lives in the resilience plan's PKI-hygiene
appendix and the [`step-ca-jwk-break-glass.md`](step-ca-jwk-break-glass.md)
runbook. Keep both in view for a coherent end-to-end response.

## Scope

"A user's OIDC session or account is compromised — what now?" The identity
stack is **lldap** (directory: users, groups, password hashes) +
**Authelia** (authN portal + OIDC provider), both on `messeldam`. Consumers
that trust it: **step-ca** (`step-ca` public client → SSH user certs) and
**Perses** (`perses` confidential client → monitoring UI). Jellyfin binds
lldap directly.

Reach the admin surfaces from the **management zone** only:

- lldap web UI: `https://ldap.internal` (mgmt-zone-restricted; the place to
  view/disable users and edit group membership).
- Authelia storage: SQLite at `/var/lib/authelia-main/db.sqlite3` on
  `messeldam` (sessions, TOTP secrets, regulation state).
- lldap durable state: SQLite under `/var/lib/private/lldap` on `messeldam`.

> Decrypts and live edits below touch secrets — run them yourself; don't have
> automation do it (see [[feedback_user_runs_secret_decrypt]]). Secrets are
> sops-encrypted in `hosts/calvard/microvm/guests/messeldam/secrets/secrets.yaml`.

## Triage order (fastest containment first)

1. **Disable the account** (cuts new logins + new token issuance). Effective
   at the _next_ auth because Authelia binds lldap per request — see §1.
2. **Revoke active sessions** (cuts existing portal sessions) — §2.
3. **Rotate signing material** only if tokens themselves may be forged or the
   issuer key is suspect — §3. Highest blast radius; do last unless the key is
   the thing that leaked.

---

## 1. Disable / lock an account

The directory is the source of truth; Authelia re-binds lldap on each request,
so a directory change propagates at the next authentication (no Authelia
restart needed).

**Preferred — lldap web UI** (`https://ldap.internal`):

- Remove the user from privileged groups (`admin`, `deploy`, `media-users`),
  or delete the user outright for full lockout. Group membership is what feeds
  SSH principals (the `groups` claim → `step-ca` SSH cert template) and service
  access, so dropping `admin`/`deploy` immediately stops new privileged certs.
- Note: `admin`, `deploy`, `media-users` and the `authelia` / `jellyfin` bind
  users are **declaratively re-seeded** by the `lldap-bootstrap` oneshot on
  each restart (`modules/.../lldap.nix`). It only _adds_ missing groups/bind
  users — it does **not** recreate a human user you delete, nor re-add a human
  to a group. So a UI removal of a compromised human account sticks. (Don't
  delete the `authelia`/`jellyfin` bind users — bootstrap recreates them and
  you'd just churn their passwords.)
- Force a password reset for the user in the same UI if the account is kept.

**Propagation timing:** the next time the user (or their stolen session) hits
a protected flow, Authelia re-binds lldap and the change is in effect. Existing
_already-issued_ artifacts persist until they expire — that's what §2 (sessions)
and the short cert lifetimes handle.

## 2. Revoke active Authelia sessions

Authelia persists sessions in `/var/lib/authelia-main/db.sqlite3` (encrypted
with `authelia-storage-encryption-key`). There is no first-class "revoke
session" CLI in the pinned version, so use one of:

- **Targeted (preferred):** delete the user's session rows from the SQLite
  store, then the stolen cookie no longer maps to a live session.
  ```sh
  # On messeldam. Inspect the schema for the pinned Authelia version first —
  # table/column names are version-specific; do NOT assume.
  sqlite3 /var/lib/authelia-main/db.sqlite3 '.tables'
  # identify the session table, then scope a delete to the affected username.
  ```
  Verify against the running version's schema before deleting — capture a copy
  of the DB first (`cp db.sqlite3 db.sqlite3.bak`).
- **Blunt (all users):** rotate `authelia-storage-encryption-key` (§3) — this
  invalidates _every_ persisted session at once. Use when you can't safely
  scope to one user or want a clean break.

After either, the account should already be disabled (§1) so the user can't
just re-establish a session.

## 3. Rotate signing / encryption material

All live in sops (`…/messeldam/secrets/secrets.yaml`), read by the
`authelia-main` user. Edit with `sops`, redeploy `messeldam`, and note the
blast radius — every affected consumer re-authenticates.

| Secret                             | Rotate when                                      | Blast radius                                                                                                      | Regenerate with           |
| ---------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- | ------------------------- |
| `authelia-oidc-issuer-private-key` | OIDC tokens may be forged / issuer key suspect   | **All OIDC consumers** (step-ca SSH issuance, Perses) must re-auth; in-flight ID tokens stop validating           | `openssl genrsa 4096`     |
| `authelia-storage-encryption-key`  | Session store compromised, or blunt session-wipe | **Every** persisted session + stored TOTP secret invalidated (users re-enroll MFA if/when F1 lands)               | `openssl rand -hex 48`    |
| `authelia-jwt-secret`              | Identity-verification (reset/2FA) JWTs suspect   | Pending password-reset / identity-verification links break                                                        | `openssl rand -hex 48`    |
| `authelia-oidc-hmac-secret`        | OIDC client-flow integrity suspect               | OIDC authorization-code flows reset                                                                               | `openssl rand -hex 48`    |
| `authelia-ldap-bind-password`      | Authelia↔lldap bind creds leaked                 | Must also update the lldap side (`authelia-password:` in `lldap-bootstrap`); Authelia can't bind until both match | `openssl rand -base64 24` |

After rotating `authelia-oidc-issuer-private-key`, expect **step-ca** to need a
fresh OIDC login for the next SSH cert and **Perses** sessions to drop. If the
rich IdP is down _during_ this work, operator SSH still works via the
[`step-ca-jwk-break-glass.md`](step-ca-jwk-break-glass.md) JWK path (it doesn't
depend on the issuer key).

## 4. Certificate side (cross-reference, not duplicated here)

There is **no CRL/OCSP** — certificate revocation relies on short lifetimes:

- **SSH user certs** (OIDC or JWK) are short-lived; a compromised cert ages out
  fast, and disabling the account (§1) stops _re-issuance_.
- **ACME service certs** (45–90d) and **fleet X5C mTLS certs** (365d) have no
  revocation path — a compromised fleet host's client cert is valid until
  expiry. To contain one, re-sign/rotate the host's enrollment material and
  redeploy; consider shortening the fleet mTLS lifetime (resilience plan, open
  decision #3).
- The **JWK provisioner password** is rotated by regenerating the key material
  and redeploying basel — see `step-ca-jwk-break-glass.md` § "Generate /
  rotate".

## 5. Headscale / friend node identity (future)

Not yet deployed. When headscale lands
([`headscale-integration-plan.md`](../plans/headscale-integration-plan.md)),
friend enrollment is via pre-authkeys (not OIDC), so revoking a friend is a
**headscale node/pre-authkey** operation, separate from §§1–3. This section
gets filled in when that work starts; cross-link its revocation steps here.

## Post-incident

- Confirm the change in the **audit trail**: Authelia auth events ship to
  VictoriaLogs on `tharbad` via messeldam's fluent-bit journal input — query
  `SYSTEMD_UNIT = "authelia-main.service"` for the affected user (follow-up F2
  adds a saved Perses panel for this).
- Re-enable / re-provision the account once clean; if a human account was
  deleted, recreate it in the lldap UI and re-add group membership.
