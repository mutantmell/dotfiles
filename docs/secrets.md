# Secrets Management

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix). All secrets
files are encrypted with [age](https://age-encryption.org/) and live at
`hosts/*/secrets/secrets.yaml`. Decryption rules are in `.sops.yaml` at the repo root.

Recipients use age's **native hybrid post-quantum** scheme (ML-KEM-768 + X25519,
recipient format `age1pq1…`, identity format `AGE-SECRET-KEY-PQ-1…`). This is
decrypted by stock sops (≥ 3.12, which vendors age ≥ 1.3) with no plugin. See
[`host-identity.md`](host-identity.md) for how the PQC key relates to the host's
(still Ed25519) SSH identity.

---

## How It Works

Each secrets file is encrypted to **two recipients**:

1. **Admin key** (`admin`) — a personal PQC age identity held off-host, in `passage`
   at `sops/key`. It lets the operator edit any secret from the workstation without
   booting the target host. `sops` loads it at invocation time via
   `home.sessionVariables.SOPS_AGE_KEY_CMD = "passage show sops/key"` (set in
   `home/hosts/edith.nix`) — there is no admin identity file at rest on the
   workstation.
2. **Host key** (`sv_<host>`) — a dedicated PQC age identity generated per host.
   The running system decrypts secrets at boot via sops-nix.

`sops-nix` reads the host's private identity at runtime via `age.keyFile` in each
host's `sops.nix` (it does **not** derive the recipient from the SSH host key — that
coupling was removed in the PQC migration). The identity file path follows a fixed
convention:

| Host type                 | `age.keyFile` path                  | How it gets there                                                                         |
| ------------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------- |
| Bare-metal (impermanence) | `/persist/var/lib/sops-nix/key.txt` | Placed by `deploy-nixos-anywhere.sh` via `--extra-files`; on `/persist` (`neededForBoot`) |
| microVM / Incus guest     | `/static/var/lib/sops-nix/key.txt`  | On the parent at `/persist/guests/<g>/static/…`, exposed via the virtiofs `/static` share |
| arcus (no impermanence)   | `/var/lib/sops-nix/key.txt`         | Persists directly on its normal root filesystem                                           |
| OpenWrt                   | — (no on-device key)                | Secrets are pushed at deploy time; only the admin recipient decrypts them                 |

Each host's PQC identity is backed up in `passage` at `hosts/<host>/age.key`
(the admin identity's source of truth is `passage:sops/key` itself).

### Generating a host identity

`scripts/deploy-nixos-anywhere.sh` (bare-metal) and `scripts/setup-guest.sh`
(guests) generate the PQC identity automatically:

```bash
age-keygen -pq -o age.key      # private identity (AGE-SECRET-KEY-PQ-1…)
age-keygen -y age.key          # derive the age1pq1… recipient
```

They store it in `passage` and place it at the path above. To re-key an existing
host manually, generate a new identity, replace its `&sv_<host>` recipient value in
`.sops.yaml`, run `sops updatekeys` on that host's secret files, and ship the new
key file.

### Encrypting / editing a secrets file

`.sops.yaml` creation rules control which recipients are used per path. Always let
sops select recipients automatically from `.sops.yaml`:

```bash
# Edit existing:
sops hosts/<host>/secrets/secrets.yaml

# Create new (creation rule must already exist in .sops.yaml):
sops hosts/<host>/secrets/secrets.yaml
```

After changing a recipient in `.sops.yaml`, re-key the affected files:

```bash
sops updatekeys hosts/<host>/secrets/secrets.yaml
```

### Adding a new host

1. Add a `&sv_<host>` anchor and a `creation_rule` for its secrets path to
   `.sops.yaml` (see below). The deploy scripts populate the anchor value with the
   generated recipient.
2. Deploy with `deploy-nixos-anywhere.sh` (bare-metal) or `setup-guest.sh` (guest) —
   the PQC identity is generated, backed up to passage, and placed on the host.
3. Encrypt the secrets file: `sops hosts/<host>/secrets/secrets.yaml`.

---

## Recipient Registry

`.sops.yaml` is the **authoritative registry** of recipients and creation rules —
it is not duplicated here (the PQC recipients are ~600-character `age1pq1…` strings).

- The `keys:` section declares each anchor: `&admin` (the workstation/admin
  identity) and one `&sv_<host>` per host.
- Each `creation_rule` maps a secrets path to `[*admin, *sv_<host>]`, except
  `hosts/openwrt/secrets/…`, which is encrypted to `*admin` only (OpenWrt devices
  hold no on-device decryption key).

To see the current set:

```bash
grep -E '&(admin|sv_)' .sops.yaml      # anchors
grep path_regex .sops.yaml             # creation rules
```

A host's per-host secret inventory lives alongside its config (`hosts/<host>/secrets/`
and the `sops.secrets`/`sops.templates` declarations in that host's modules) — those
are the source of truth for _what_ each host decrypts.

---

## Notes

- **Admin key recovery.** The admin PQC identity lives only in `passage:sops/key`
  (no plaintext at rest). Losing it means losing the ability to edit any secret
  off-host; each host can still decrypt its own secrets with its `age.keyFile`
  identity. Treat passage-store availability as load-bearing (it already is for
  PKI CA keys, disk keys, etc.).
- **Lost host identity.** Restore from `passage:hosts/<host>/age.key`, or generate a
  new identity and re-key that host's files (see "Generating a host identity").
- **No mixed-recipient files.** age refuses to encrypt one file to both classical
  X25519 and PQ recipients; every secrets file is fully PQ. This was the invariant
  that made the SSH-key → PQC migration safe (see
  `llm-notes/done/pqc-sops-migration-plan.md`).
