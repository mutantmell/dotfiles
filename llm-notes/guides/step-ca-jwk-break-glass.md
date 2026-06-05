# step-ca JWK break-glass SSH access

**Status:** operator-facing runbook for the IdP-independent SSH-user-cert
path on `basel` (step-ca). Companion to
[`foundational-identity-resilience-plan.md`](../wip/foundational-identity-resilience-plan.md)
(Phase A, which shipped this provisioner).

## When to use this

Use the `admin-jwk` provisioner when the **rich IdP is unavailable** and you
still need a real SSH certificate:

- Authelia / lldap on `messeldam` is down, mid-reboot, or cold-booting.
- step-ca is up (it has to be — it's the CA) but its `authelia` OIDC
  provisioner can't complete discovery yet (the
  `step-ca <-> Authelia` cold-boot loop that `step-ca-oidc-retry` works
  around).

This path **does not touch Authelia or lldap**. It authorizes the cert
request with an offline JWK password instead of an OIDC login, and step-ca
signs with its existing SSH **user** CA. The daily path stays OIDC
(`provisioner = "authelia"`, the default in `modules/common/ssh-cert-client.nix`).

### Three-ring operator access model (context)

| Ring | Credential | Available when the rich IdP is… |
| ---- | ---------- | ------------------------------- |
| 0 | raw SSH key (`keys.json` → `root`) | always (static, not identity-bound) |
| 1 | **`admin-jwk` step-ca cert** (this doc) | always (IdP-independent) |
| 2 | OIDC → Authelia step-ca cert | only when Authelia is up |

Ring 1 keeps "Authelia down / cold-booting" from forcing a drop to the raw
Ring 0 break-glass key. SSH user certs are short-lived, so a *cached* cert is
not a fallback during an outage — the **issuer** needs an IdP-independent
path, which is what this provides.

## Prerequisites

- `step-cli` on the workstation (provided by `common.ssh-cert-client.enable`).
- The **JWK provisioner password** — held offline in the operator `passage`
  vault, **not** on any host. step-ca holds only the public key plus the
  password-encrypted private key (`encryptedKey` in its config); the password
  is the secret that unlocks it. See [[feedback_no_passage_store_reads]] —
  retrieve it via the `passage` CLI.
- Network reachability to `basel.internal:443` (the CA). No path to messeldam
  is needed.

## Issue a break-glass certificate

```sh
# Override the default 'authelia' provisioner with the offline JWK path.
step ssh certificate admin ~/.ssh/id_ed25519 --provisioner admin-jwk
#   → prompts: "Please enter the password to decrypt the provisioner key:"
#     (the JWK password from passage; step-cli decrypts locally, the password
#      never leaves the workstation)
#   → writes ~/.ssh/id_ed25519-cert.pub
```

Then SSH as normal — `programs.ssh` already presents
`~/.ssh/id_ed25519-cert.pub` to `*.internal` hosts.

**The emitted principal is always `admin`.** `admin-jwk.tpl` hard-codes it and
ignores any `--principal` you pass; `policy.ssh.user.allow.principals =
["admin" "deploy"]` on step-ca is the defense-in-depth backstop. You cannot
mint a `root` (or any non-`admin`/`deploy`) principal through this provisioner.

> **First-run note:** this provisioner is verified at the Nix level
> (renders into basel's config; compact-JWE `encryptedKey`, public-only `key`)
> but the *runtime* issue-and-login round trip is validated on first real use.
> If `step ssh certificate` rejects the `encryptedKey`, see "Key material"
> below — the most likely cause is a JWE-format mismatch.

### No renewal — re-issue

JWK cannot renew/rekey SSH certs (that needs a companion SSHPOP provisioner,
which we don't run). These certs are short-lived by design; when one expires,
**re-issue** with the command above. Do not build tooling around `step ssh
renew` for this path.

## Key material

Lives in `lib/common/data/pki/`, referenced by `data.pki.adminJwk` and wired
into `basel`'s step-ca in
`hosts/calvard/microvm/guests/basel/modules/step-ca.nix`:

- `admin_jwk.pub.json` — public JWK (EC P-256). Safe to commit.
- `admin_jwk.enc` — the private JWK encrypted under the JWK password, as JWE
  **JSON serialization** (what `step crypto jwk create` emits). Safe to commit
  (it's encrypted). `step-ca.nix` joins its five segments
  (`protected.encrypted_key.iv.ciphertext.tag`) into the compact form step-ca's
  `encryptedKey` expects.

### Generate / rotate

```sh
cd lib/common/data/pki
step crypto jwk create admin_jwk.pub.json admin_jwk.enc --kty EC --crv P-256
#   → prompts for a password; choose a strong one and store it in passage.
git add admin_jwk.pub.json admin_jwk.enc      # both are commit-safe
```

Rotate by regenerating (new password) and redeploying `basel`. Rotation
invalidates the old password immediately at the CA — there is no separate
revocation step for the provisioner itself. Any already-issued SSH user certs
remain valid until they expire (no CRL; short lifetimes are the control — see
the resilience plan's PKI-hygiene appendix and the companion
[`authelia-incident-response.md`](authelia-incident-response.md) runbook).

## Validate after a basel deploy

1. **With Authelia stopped on messeldam** (`systemctl stop authelia-main`),
   run the issue command above → a cert with `Principals: admin` is produced
   and SSH into `calvard` / `liberl` / `thebeyond` succeeds.
2. A request for a `root` principal still yields an `admin`-only cert (the
   template overrides requester input) and cannot escalate.
3. Restart Authelia; confirm the daily OIDC path
   (`step ssh certificate … --provisioner authelia`, or the default) still
   works.
