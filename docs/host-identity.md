# Host Identity & Cryptographic Posture

This document describes how each host in the fleet proves its identity, what
distinct cryptographic materials live on each host and why, and how those
materials interact with the rest of the security stack (sops, mTLS, web TLS,
SSH).

The guiding principle: **identity is established out-of-band; authorization
is gated on identity.** Keys (and the certificates that bind them to a
hostname) answer "who is this host?" Sops answers "given who you are, what
secrets may you read?" These two layers are deliberately kept separate so
that a compromise in one does not cascade into the other.

This is the same pattern formalized by SPIFFE/SPIRE (identity vs. policy),
recommended by NIST SP 800-207 (zero trust architecture), and surfaced by
HashiCorp as the "secret zero" problem: the bootstrap secret that unlocks
your secrets manager must itself be delivered through a different channel.

---

## Per-Host Identity Materials

Each host carries up to **four** distinct cryptographic identities, each with
its own trust root, lifetime, and purpose. They are conceptually independent —
the failure or rotation of one does not require rotating the others.

| Material            | Trust root                          | Used for                               | Generated  | Distributed via            |
| ------------------- | ----------------------------------- | -------------------------------------- | ---------- | -------------------------- |
| SSH host key + cert | Offline SSH host CA                 | Authenticating SSH connections         | On host    | Pubkey + cert in repo      |
| X5C enrollment cert | Offline fleet X5C CA                | Bootstrapping mTLS client certs        | On host    | Pubkey + cert in repo      |
| step-ca web certs   | Online intermediate CA (basel)      | TLS for HTTP services (ACME)           | On step-ca | Issued at runtime via ACME |
| PQC age key         | None (self-asserted; pubkey in cfg) | Decrypting sops secrets (post-quantum) | On host    | Pubkey in `.sops.yaml`     |

The first two are signed by **offline CAs** whose private keys never live
on any networked host — they are held in operator-only offline storage and
only loaded transiently when signing. The third (web certs) is issued by an
**online CA** that is itself bootstrapped from offline material. The fourth
(PQC age key) is **self-asserted** — there is no CA, the public key is
registered directly in `.sops.yaml`.

---

## SSH Host Key + Certificate

**Purpose.** Authenticates the host to SSH clients and (transitively) anyone
who accepts `@cert-authority` trust for the SSH host CA. Replaces the
TOFU-on-first-connect model of plain SSH host keys.

**Generated.** On the host, on first boot, by the standard NixOS
`ssh-keygen` flow. The private key never leaves the host.

**Signed by.** An offline SSH host CA (Ed25519) held in operator-only
storage. The corresponding public key is at
`lib/common/data/pki/ssh_host_ca.pub` and is checked into the repo.

**Distributed.** Public keys are registered in `lib/common/data/keys.json`
under `hostKeys`. The signed certificate (signed against the network
registry's domain list for that host) is checked into
`lib/common/data/host-certs/<hostname>-cert.pub`. Auto-discovered by
`lib/common/data/default.nix` and deployed as
`/etc/ssh/ssh_host_ed25519_key-cert.pub`.

**Rotation.** `nix run .#ssh-host-cert-sign -- --sign <hostname>` produces a
new cert valid for 731 days. Operator commits the new cert; deploy.

**CI hook.** A check can walk `lib/common/data/host-certs/`, parse each
cert's `Valid: ... to` line via `ssh-keygen -L -f`, and fail the build when
any cert expires within N days.

---

## X5C Enrollment Key + Certificate

**Purpose.** Authenticates the host to step-ca's X5C provisioner so it can
request short-lived mTLS client certificates for `fluent-bit` to push logs
to Loki and metrics to vmsingle. Replaces a previous (broken) attempt to
use SSHPOP for the same purpose — SSHPOP can only renew SSH certs, not
issue x509.

**Generated.** On the host, on first boot, via `step crypto keypair`. The
private key (`/var/lib/fleet-tls/enrollment.key`) never leaves the host.

**Signed by.** A separate offline fleet X5C CA, held in operator-only
storage alongside the SSH host CA. This CA is _only_ trusted by step-ca's
X5C provisioner — it has no other authority in the system.

**Distributed.** Public keys registered in `lib/common/data/keys.json` under
`fleetEnrollmentKeys`. Signed enrollment certs checked into
`lib/common/data/fleet-x5c-certs/<hostname>-cert.pub`. Auto-discovered
identically to SSH host certs. The CA's public certificate is at
`lib/common/data/pki/fleet_x5c_ca.crt`.

**Why a separate CA from the SSH host CA?** Two reasons. First, scoping:
the SSH host CA's authority is "I vouch for SSH host identity" — extending
it to vouch for x509 certs would conflate two trust domains. Second, blast
radius: an attacker who exfiltrates the SSH host CA can impersonate any
host over SSH but cannot mint mTLS bootstrap certs, and vice versa.

**Rotation.** `nix run .#fleet-x5c-cert-sign -- --sign <hostname>` (planned).
Same operational shape as SSH host cert signing.

**Issued mTLS certs.** Short-lived (24 hours), issued by step-ca on demand,
not stored in the repo — this is the layer where keys are actually used to
do work, and the long-lived enrollment cert is what authorizes their
issuance.

---

## step-ca-Issued Web Certificates

**Purpose.** TLS for internal HTTPS services (Grafana, Forgejo, Keycloak,
etc.). Issued via ACME (HTTP-01) by step-ca running on `basel`.

**Trust chain.** Browsers and internal callers trust the offline root and
intermediate certs at `lib/common/data/pki/{root_ca.crt,intermediate_ca.crt}`.
The intermediate's private key lives encrypted in basel's sops bundle and
is loaded by step-ca at runtime.

**Lifetime.** Short (24 hours by default), with automatic renewal. There is
no per-host long-lived material here — services request certs as needed.

**Why not use this for SSH host identity or fleet enrollment?** Two
reasons:

1. **Bootstrap dependency.** step-ca runs as a microvm on calvard. Hosts
   that need to identify themselves _to start fluent-bit_ cannot wait for
   step-ca to be up — and step-ca itself has to be reachable to issue
   certs. Out-of-band offline-CA-signed certs avoid the runtime
   dependency.
2. **Compromise scope.** If step-ca is compromised at runtime (e.g., a
   webserver bug, sops leak, host takeover), every cert it can issue is
   suspect. Keeping SSH and fleet-enrollment trust roots offline means a
   step-ca compromise does not invalidate every host's identity — it only
   invalidates the web-cert layer until step-ca is rebuilt.

---

## PQC Age Key

**Purpose.** Decrypts sops-encrypted secrets at runtime. Replaced the
former scheme where each host's SSH Ed25519 host key was converted to an
X25519 age recipient via `ssh-to-age`. See
[`secrets.md`](secrets.md) for the operational details and
`llm-notes/done/pqc-sops-migration-plan.md` for the migration.

**Why a separate key — why couldn't we keep using the SSH host key?**

The former scheme worked only because Ed25519 (signing) and X25519 (key
agreement) share the same underlying curve (Curve25519). `ssh-to-age` is a
deterministic mapping from an Ed25519 keypair to an X25519 keypair. **No
such mapping exists for post-quantum schemes.**

Post-quantum cryptography is moving toward NIST-finalized algorithms:
ML-KEM (FIPS 203, key agreement / hybrid encryption), ML-DSA (FIPS 204,
signing), and SLH-DSA (FIPS 205, hash-based signing). These are
mathematically unrelated to Curve25519. There is no derivation that turns
an Ed25519 SSH host key into an ML-KEM age recipient.

age v1.3 added first-class native PQC support (hybrid ML-KEM-768 + X25519),
so each host now has its own dedicated PQC keypair. The SSH host key
continues to do its job (SSH host identity), and the PQC key has taken
over the sops-decryption job the SSH key had been moonlighting in.

**The threat model.** Even before quantum computers exist, this matters
because of "harvest now, decrypt later" attacks. Encrypted secrets in the
repository today are durable artifacts — anyone who exfiltrates the repo
can wait. If those secrets are encrypted only to X25519 recipients, they
become vulnerable the moment a cryptographically relevant quantum computer
is deployed against them. Migrating to PQC age while CRQCs are still
hypothetical is the conservative move.

**Operational shape.**

- Generated at deploy time by `deploy-nixos-anywhere.sh` / `setup-guest.sh`
  (`age-keygen -pq`), placed on the host at `age.keyFile`, and backed up to
  `passage:hosts/<host>/age.key`.
- The `age1pq1…` recipient is registered in `.sops.yaml` (keyed by `&sv_<host>`
  alias).
- No CA — the public key is the trust anchor, registered directly in repo.
- Rotation: generate a new identity, replace the recipient in `.sops.yaml`,
  `sops updatekeys` the host's files, ship the new key file.

**Why no CA for the age key?** Because age recipients are
public-key-as-identity, not certificate-based. There is no rotation use
case where a stable host identity needs to be re-bound to a fresh keypair
mid-flight; if a host's age key changes, you re-encrypt its secrets. This
matches age's design and keeps the layer simple.

---

## Why Four Distinct Identities — Isn't This Overkill?

Each material has a distinct trust root, a distinct compromise scope, and
a distinct rotation cadence:

| Compromise of...    | What an attacker can do                   | What they cannot do                                    |
| ------------------- | ----------------------------------------- | ------------------------------------------------------ |
| One host's SSH key  | Impersonate that host to SSH clients      | Decrypt that host's sops secrets, mint mTLS certs      |
| The SSH host CA     | Impersonate any host to SSH clients       | Decrypt sops secrets, mint mTLS certs                  |
| One host's age key  | Decrypt that host's sops secrets          | Impersonate that host to SSH or step-ca                |
| One host's X5C cert | Bootstrap mTLS client certs for that host | Authenticate as that host to SSH, decrypt sops secrets |
| The fleet X5C CA    | Bootstrap mTLS client certs for any host  | Decrypt sops secrets, impersonate over SSH             |
| step-ca (online)    | Issue web certs, request mTLS bootstrap   | Decrypt sops secrets, impersonate over SSH directly    |

If a single key were re-used for all four roles, **any** compromise would
collapse the entire system into "attacker has full control." The current
split means an attacker has to compromise multiple distinct trust paths to
escalate. This is defense-in-depth applied to identity material itself.

The cost is: per-host provisioning has to deliver / generate three pieces
of material (SSH key — already auto-generated; X5C enrollment key + cert
— scripted; PQC age key — scripted). Provisioning is automated via
`scripts/setup-guest.sh`, so the marginal cost per host is low.

---

## Source-of-Truth Properties

Public keys, certificates, and CA certs all live in the repo. This gives
us several properties that a runtime secrets store (e.g., Vault) does not:

- **Auditable.** `git log lib/common/data/host-certs/` shows the rotation
  history of every host certificate, who rotated it, and when.
- **Diffable.** A reviewer sees in a PR diff whether the right cert is
  being added for the right host. Accidental swap is visible.
- **Reproducible.** Any commit reproduces the trust state exactly. There
  is no drift between "what the system trusts" and "what the repo says
  the system trusts."
- **CI-checkable.** Cert expiry, registry/cert consistency, and orphaned
  certs can all be validated as part of `./scripts/run-checks.sh`. Cert
  expiry becomes a failed-PR-check rather than a pager incident.

The corresponding cost is that rotation requires a commit and redeploy —
not a runtime API call. At fleet scale this would become friction; at
~14 hosts it is preferable to the alternative.

---

## When This Posture Would Need to Change

The current model is right-sized for the current scale. It would need to
evolve if:

- **Fleet grows substantially** (e.g., >50 hosts). The signing-app
  workflow is fine for tens of hosts; at hundreds, an online issuance
  flow (still gated on hardware-attestable identity) would scale better.
- **Services outside the repo need secrets.** Today every consumer is in
  the flake. A non-Nix workload (a third-party container, a guest user)
  needing dynamic secrets would push us toward Vault or similar.
- **Hardware-attested identity becomes available.** TPM-backed keys would
  let us tighten the threat model further: even an operator with full
  access to the offline CA material cannot mint a fake host identity if
  the trust anchor is a TPM measurement. This is forward-compatible —
  the X5C/age model would layer on top of TPM attestation rather than
  replace it.

Until then, four out-of-band identity materials per host is the minimum
viable shape, not over-engineering.
