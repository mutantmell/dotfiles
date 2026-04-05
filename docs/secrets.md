# Secrets Management

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix). All secrets
files are encrypted with [age](https://age-encryption.org/) and live at
`hosts/*/secrets/secrets.yaml`. Decryption rules are in `.sops.yaml` at the repo root.

---

## How It Works

Each secrets file is encrypted to **two recipients**:

1. **Admin key** (`ad_denai`) — a personal age key held off-host. Allows editing secrets
   from any workstation without booting the target host first.
2. **Host key** — the host's SSH ed25519 key, converted to an age recipient. The running
   system uses this to decrypt secrets at boot via sops-nix.

`sops-nix` locates the private key at runtime via `age.sshKeyPaths` in each host's
`sops.nix`. For microVMs this is always `/static/etc/ssh/ssh_host_ed25519_key` (served
via a virtiofs/9p share from the parent host). For bare-metal hosts it is
`/etc/ssh/ssh_host_ed25519_key`.

The admin key is stored at `.keys/` (not committed to the repo). Guest SSH host keys
used solely for sops decryption can also be stored there for reference.

### Deriving an age recipient from an SSH key

```bash
# From a public key file:
ssh-to-age < /path/to/ssh_host_ed25519_key.pub

# From a running host (known_hosts):
ssh-keyscan <host> | ssh-to-age
```

### Encrypting / editing a secrets file

`.sops.yaml` creation rules control which age keys are used per path. Always let sops
select keys automatically from `.sops.yaml`:

```bash
# Edit existing:
sops hosts/<host>/secrets/secrets.yaml

# Create new:
sops --encrypt hosts/<host>/secrets/secrets.yaml > hosts/<host>/secrets/secrets.yaml
```

### Adding a new guest host

1. Boot the guest once (SSH host key is generated on first boot).
2. Retrieve the public key from `/static/etc/ssh/ssh_host_ed25519_key.pub` (on the
   parent hypervisor).
3. Convert to age: `ssh-to-age < ssh_host_ed25519_key.pub`
4. Add an alias and creation rule to `.sops.yaml`.
5. Re-encrypt the secrets file: `sops updatekeys hosts/<guest>/secrets/secrets.yaml`
   (or delete and recreate the placeholder file).

---

## Age Key Registry

| Alias          | Host                                 | Source                                 | Age Public Key                                                   |
| -------------- | ------------------------------------ | -------------------------------------- | ---------------------------------------------------------------- |
| `ad_denai`     | admin workstation                    | personal key                           | `age1mmqej3arlv2wx96m2gh9fgvqpkwaeselzfu4rqfn54artx058vys7g3ehq` |
| `sv_thebeyond` | thebeyond                            | `/etc/ssh/ssh_host_ed25519_key`        | `age1xvkjw03zrcy38rxmlhawzqdzlm34cx98mc42v5caautaauj8dd5qddg9hm` |
| `sv_phantasma` | phantasma                            | `/static/etc/ssh/ssh_host_ed25519_key` | `age128p6n3akchec88ptd6anpcssxzr9t3h4y0xzc6dkcsh6g3h46qmssy76fh` |
| `sv_liberl`    | liberl                               | `/etc/ssh/ssh_host_ed25519_key`        | `age18e698z5sf5twkc8vup4edc7nkaza2nquuzqja8lrv7r34mzx84js48jps0` |
| `sv_zeiss`     | zeiss                                | `/static/etc/ssh/ssh_host_ed25519_key` | `age1dvk7gqyw4zwnnu6u3dwke94unlkw85kmlw6s5lfq59jw32s5zdks4c32ff` |
| `sv_calvard`   | calvard                              | `/etc/ssh/ssh_host_ed25519_key`        | `age1jnpyg8chayw6l9wfx209hvkddq9cult3qdyuf7trljs6t5vf3czseu8qlm` |
| `sv_erebonia`  | erebonia                             | `/etc/ssh/ssh_host_ed25519_key`        | `age1328qtjtudgc3zgg7su05ja20kckx50jehs0v3q3mw6k64j0dzefs752tu2` |
| `sv_azoth`     | azoth                                | `/etc/ssh/ssh_host_ed25519_key`        | `age18qjk9pk7z7lyjkwlkthee3pcywupxs2jxdcczmngdrjwmxgytdnsakwks9` |
| `sv_trista`    | trista                               | SSH host key                           | `age1v2vrn026vtgfkw8v2uez4ljhz44f8j27y5ueacphk8n2lr6q8cjs583tcm` |
| `sv_ordis`     | ordis (decommissioned → langport)    | `/static/etc/ssh/ssh_host_ed25519_key` | `age1fekpnwvr7xzkfmwx0t3ar3h0e6sdl5jxskupy2hnzc4d08c9mv2qz3ksx7` |
| `sv_ymir`      | ymir (decommissioned → tharbad)      | `/static/etc/ssh/ssh_host_ed25519_key` | `age1anrdj6swtlq5ll4e369gz3lh6aj2sz6pj5zh25uhltjfk4z86azsfsxk9a` |
| `sv_heimdallr` | heimdallr (decommissioned → oracion) | SSH host key                           | `age1exkagk0ztmnw7kvx3wwwqjgx3m2zxycgg46xmrt7pvqlngqgjyeqc4ajqh` |
| `sv_denai`     | denai                                | SSH host key                           | `age19d3g52d9vn37n9z2ezrj37n6svk9vjxdm6tmnjchklh9muhdpqfs4xvea7` |

### Keys needed — not yet in registry

These guest hosts have sops secrets configured but **no age key in `.sops.yaml`** yet.
Keys must be retrieved after the first deployment of each guest.

| Host       | Config Path                         | Needs Key For                                                        |
| ---------- | ----------------------------------- | -------------------------------------------------------------------- |
| messeldam  | `hosts/calvard/guests/messeldam/`   | `keycloak_password_file`                                             |
| basel      | `hosts/calvard/guests/basel/`       | `intermediate_ca.key`, `intermediate-password-file`                  |
| langport   | `hosts/calvard/guests/langport/`    | `wireguard_private_key`, `wg_ba_peer_*`, `oauth-2-proxy-keyfile`     |
| tharbad    | `hosts/calvard/guests/tharbad/`     | `grafana-admin-password`, `alertmanager-ntfy-url`, `ntfy-auth-token` |
| saint-arkh | `hosts/erebonia/guests/saint-arkh/` | `forgejo-runner-token`                                               |

---

## `.sops.yaml` Creation Rules

### Current rules

| Path Pattern                                | Recipients                                            |
| ------------------------------------------- | ----------------------------------------------------- |
| `hosts/thebeyond/secrets/`                  | `ad_denai`, `sv_thebeyond`                            |
| `hosts/thebeyond/guests/phantasma/secrets/` | `ad_denai`, `sv_phantasma`                            |
| `hosts/liberl/secrets/`                     | `ad_denai`, `sv_liberl`                               |
| `hosts/liberl/guests/zeiss/secrets/`        | `ad_denai`, `sv_zeiss`                                |
| `hosts/erebonia/secrets/`                   | `ad_denai`, `sv_erebonia`                             |
| `hosts/erebonia/guests/ordis/secrets/`      | `ad_denai`, `sv_ordis`                                |
| `hosts/erebonia/guests/ymir/secrets/`       | `ad_denai`, `sv_ymir`                                 |
| `hosts/azoth/secrets/`                      | `ad_denai`, `sv_azoth`                                |
| `hosts/calvard/secrets/`                    | `ad_denai`, `sv_calvard`                              |
| `hosts/calvard/guests/heimdallr/secrets/`   | `ad_denai`, `sv_heimdallr`                            |
| `hosts/calvard/guests/trista/secrets/`      | `ad_denai`, `sv_trista`                               |
| `hosts/openwrt/secrets/`                    | `ad_denai` only (OpenWrt devices don't hold age keys) |

### Missing rules — must be added after first deployment

These paths have secrets files but no creation rule in `.sops.yaml`:

| Path Pattern                                | Recipients Needed                                           |
| ------------------------------------------- | ----------------------------------------------------------- |
| `hosts/calvard/guests/messeldam/secrets/`   | `ad_denai`, `sv_messeldam` (TBD)                            |
| `hosts/calvard/guests/basel/secrets/`       | `ad_denai`, `sv_basel` (TBD)                                |
| `hosts/calvard/guests/langport/secrets/`    | `ad_denai`, `sv_langport` (TBD)                             |
| `hosts/calvard/guests/tharbad/secrets/`     | `ad_denai`, `sv_tharbad` (TBD)                              |
| `hosts/erebonia/guests/saint-arkh/secrets/` | `ad_denai`, `sv_saint_arkh` (TBD)                           |

---

## Secrets Inventory

### thebeyond — Router

| Secret                 | Purpose                            | Status      |
| ---------------------- | ---------------------------------- | ----------- |
| `wg-vpn-privatekey`    | WireGuard VPN private key          | Encrypted ✓ |
| `wg-ba-privatekey`     | WireGuard wg-ba tunnel private key | Encrypted ✓ |
| `dyndns-host-domain`   | Dynamic DNS hostname               | Encrypted ✓ |
| `dyndns-host-password` | Dynamic DNS update password        | Encrypted ✓ |

`sops.nix`: `age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"]` ✓

---

### phantasma — DNS/Adguard (thebeyond guest)

| Secret                          | Purpose                    | Status               |
| ------------------------------- | -------------------------- | -------------------- |
| `oauth2-proxy-internal-keyfile` | oauth2-proxy cookie secret | Commented out (TODO) |

`sops.nix`: `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]` ✓

**Note:** The oauth2-proxy secret is commented out in `sops.nix` pending messeldam and
basel deployment (see the TODO comment). The secrets file currently holds a placeholder
`test` value and must be updated once oauth2-proxy is re-enabled.

---

### liberl — NAS

| Secret            | Purpose                 | Status                               |
| ----------------- | ----------------------- | ------------------------------------ |
| `upsmon.password` | UPS monitoring password | Encrypted ✓ (reusing remiferia keys) |

`sops.nix`: `age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"]` ✓ (reusing remiferia keys)

---

### calvard — VM Host

| Secret          | Purpose                                                | Status                                       |
| --------------- | ------------------------------------------------------ | -------------------------------------------- |
| `chap-secrets`  | PPPoE CHAP credentials (path: `/etc/ppp/chap-secrets`) | **Not encrypted** (TODO comment in sops.nix) |
| `pppd-userfile` | PPP user file                                          | **Not encrypted** (TODO comment in sops.nix) |

`sops.nix`: **No `age.sshKeyPaths` set** — calvard cannot decrypt at runtime until
this is added. Secrets file `hosts/calvard/secrets/secrets.yaml` does not exist yet.

**Action required:** Add `age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"]` to
`hosts/calvard/sops.nix` and create + encrypt `hosts/calvard/secrets/secrets.yaml`.

---

### zeiss — Attic Binary Cache (liberl guest)

| Secret      | Purpose                                                       | Status                            |
| ----------- | ------------------------------------------------------------- | --------------------------------- |
| `attic.env` | Attic server environment (token signing key, S3 config, etc.) | Encrypted ✓ (reusing ardent keys) |

`sops.nix`: `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]` ✓ (reusing ardent keys)

---

### messeldam — Keycloak OIDC (calvard guest)

| Secret                   | Purpose                 | Status                                |
| ------------------------ | ----------------------- | ------------------------------------- |
| `keycloak_password_file` | Keycloak admin password | **PLACEHOLDER** — needs re-encryption |

`sops.nix`: `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]` ✓

**Action required:** After first boot of messeldam:

1. Retrieve `ssh_host_ed25519_key.pub` from `/persist/guests/messeldam/static/etc/ssh/` on calvard.
2. Derive age key: `ssh-to-age < ssh_host_ed25519_key.pub`
3. Add `sv_messeldam` alias and creation rule for `hosts/calvard/guests/messeldam/secrets/` to `.sops.yaml`.
4. Choose an admin password and encrypt: `sops hosts/calvard/guests/messeldam/secrets/secrets.yaml`

---

### basel — step-ca PKI (calvard guest)

| Secret                       | Purpose                                                   | Status                                |
| ---------------------------- | --------------------------------------------------------- | ------------------------------------- |
| `intermediate_ca.key`        | Intermediate CA private key (mode 0400, owned by step-ca) | **PLACEHOLDER** — needs re-encryption |
| `intermediate-password-file` | Password protecting the intermediate CA key               | **PLACEHOLDER** — needs re-encryption |

`sops.nix`: `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]` ✓

**Action required:** After first boot of basel:

1. Retrieve age key from basels SSH host key (same procedure as messeldam).
2. Add `sv_basel` to `.sops.yaml`.
3. Generate the intermediate CA keypair (from step-ca init or your existing CA material).
4. Encrypt: `sops hosts/calvard/guests/basel/secrets/secrets.yaml`

**Note:** The legacy `legram` secrets file (`hosts/erebonia/guests/legram/secrets/`) also
holds PLACEHOLDERs and can be left in place (legram is decommissioned) or removed.

---

### langport — Reverse Proxy (calvard guest)

| Secret                  | Purpose                                | Status                                |
| ----------------------- | -------------------------------------- | ------------------------------------- |
| `wireguard_private_key` | WireGuard private key for wg-ba tunnel | **PLACEHOLDER** — needs re-encryption |
| `wg_ba_peer_1_address`  | WireGuard peer 1 endpoint address      | **PLACEHOLDER**                       |
| `wg_ba_peer_2_address`  | WireGuard peer 2 endpoint address      | **PLACEHOLDER**                       |
| `oauth-2-proxy-keyfile` | oauth2-proxy cookie encryption key     | **PLACEHOLDER**                       |

`sops.nix`: **No `age.sshKeyPaths` set** — langport cannot decrypt at runtime.

**Action required:**

1. Add `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]` to `hosts/calvard/guests/langport/sops.nix`.
2. After first boot, derive and register `sv_langport` age key.
3. Migrate WireGuard keys from `hosts/erebonia/guests/ordis/secrets/secrets.yaml` (those are the ordis keys and can be re-used or regenerated).
4. Encrypt: `sops hosts/calvard/guests/langport/secrets/secrets.yaml`

The `ordis` secrets file has real encrypted values for all four fields; the WireGuard
keys and oauth2-proxy keyfile from ordis can be reused for langport if ordis has not
yet been decommissioned, or regenerated freshly.

---

### tharbad — Monitoring (calvard guest)

| Secret                   | Purpose                                     | Status                                |
| ------------------------ | ------------------------------------------- | ------------------------------------- |
| `grafana-admin-password` | Grafana admin UI password                   | **PLACEHOLDER** — needs re-encryption |
| `alertmanager-ntfy-url`  | ntfy push notification URL for Alertmanager | **PLACEHOLDER**                       |
| `ntfy-auth-token`        | ntfy authentication token                   | **PLACEHOLDER**                       |

`sops.nix`: `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]` ✓

**Action required:** After first boot of tharbad:

1. Derive and register `sv_tharbad` age key.
2. Migrate values from `hosts/erebonia/guests/ymir/` (ymir has the same secret layout).
3. Encrypt: `sops hosts/calvard/guests/tharbad/secrets/secrets.yaml`

---

### saint-arkh — Forgejo Actions Runners (erebonia guest)

| Secret                 | Purpose                                   | Status                                |
| ---------------------- | ----------------------------------------- | ------------------------------------- |
| `forgejo-runner-token` | Forgejo Actions runner registration token | **PLACEHOLDER** — needs re-encryption |

`sops.nix`: `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]` ✓

**Action required:**

1. Deploy creil (Forgejo) first.
2. In the Forgejo admin UI (`https://creil.internal/admin/runners`), generate a runner
   registration token.
3. After first boot of saint-arkh, derive and register `sv_saint_arkh` age key.
4. Encrypt: `sops hosts/erebonia/guests/saint-arkh/secrets/secrets.yaml`

---

### azoth — IoT/Smart Home Hub

| Secret            | Purpose                                        | Status      |
| ----------------- | ---------------------------------------------- | ----------- |
| `wpa.env`         | WPA supplicant credentials for wireless uplink | Encrypted ✓ |
| `zwavejs.secrets` | Z-Wave JS server secret keys                   | Encrypted ✓ |

`sops.nix`: `age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"]` ✓

---

## Decommissioned / Legacy Secrets

These secrets files belong to hosts that have been or are being replaced. They can be
left in place for data-migration reference and removed once migration is complete.

| Host   | Path                            | Replacement | Notes                                                                                      |
| ------ | ------------------------------- | ----------- | ------------------------------------------------------------------------------------------ |
| ordis  | `hosts/erebonia/guests/ordis/`  | langport    | Contains real WireGuard + oauth2-proxy keys; copy to langport before decommissioning       |
| roer   | `hosts/erebonia/guests/roer/`   | messeldam   | Placeholder only                                                                           |
| legram | `hosts/erebonia/guests/legram/` | basel       | Placeholder only                                                                           |
| ymir   | `hosts/erebonia/guests/ymir/`   | tharbad     | Has `grafana-admin-password`, `alertmanager-ntfy-url`, `ntfy-auth-token` — copy to tharbad |

---

## Pending Work Summary

### `.sops.yaml` updates needed

After deploying each new calvard/erebonia guest, add an age key alias and creation rule:

```yaml
# Add to keys section:
- &sv_messeldam  <age key from messeldam SSH host key>
- &sv_basel      <age key from basel SSH host key>
- &sv_langport   <age key from langport SSH host key>
- &sv_tharbad    <age key from tharbad SSH host key>
- &sv_saint_arkh <age key from saint-arkh SSH host key>

# Add creation rules:
- path_regex: hosts/calvard/guests/messeldam/secrets/[^/]+\.yaml$
  key_groups:
    - age:
      - *ad_denai
      - *sv_messeldam

- path_regex: hosts/calvard/guests/basel/secrets/[^/]+\.yaml$
  key_groups:
    - age:
      - *ad_denai
      - *sv_basel

- path_regex: hosts/calvard/guests/langport/secrets/[^/]+\.yaml$
  key_groups:
    - age:
      - *ad_denai
      - *sv_langport

- path_regex: hosts/calvard/guests/tharbad/secrets/[^/]+\.yaml$
  key_groups:
    - age:
      - *ad_denai
      - *sv_tharbad

- path_regex: hosts/erebonia/guests/saint-arkh/secrets/[^/]+\.yaml$
  key_groups:
    - age:
      - *ad_denai
      - *sv_saint_arkh
```

### `sops.nix` fixes needed

| Host       | Fix                                                                                                  |
| ---------- | ---------------------------------------------------------------------------------------------------- |
| `calvard`  | Add `age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"]`; create and encrypt `secrets/secrets.yaml` |
| `zeiss`    | Add `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]`                                     |
| `denai`    | Add `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]` (if denai is kept)                  |
| `langport` | Add `age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"]`                                     |

### Secrets to migrate from decommissioned guests

| From  | Secret                                         | To       | Action                                                              |
| ----- | ---------------------------------------------- | -------- | ------------------------------------------------------------------- |
| ordis | `wireguard_private_key`                        | langport | Reuse or regenerate — same WG interface                             |
| ordis | `wg_ba_peer_1_address`, `wg_ba_peer_2_address` | langport | Copy verbatim                                                       |
| ordis | `oauth-2-proxy-keyfile`                        | langport | Copy verbatim (same cookie secret = existing sessions remain valid) |
| ymir  | `grafana-admin-password`                       | tharbad  | Copy (or set a new password)                                        |
| ymir  | `alertmanager-ntfy-url`                        | tharbad  | Copy verbatim                                                       |
| ymir  | `ntfy-auth-token`                              | tharbad  | Copy verbatim                                                       |
