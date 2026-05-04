# Erebonia Fleet Enrollment Checklist

Enroll erebonia and its guests (roer, saint-arkh, trista) into the X5C
fleet-enrollment flow so fluent-bit can bootstrap a client cert and
ship logs/metrics to tharbad. Mirrors the calvard enrollment from
commits `bed327c` ("fleet: enroll calvard and guests") and `630b741`
("add missing guest certs"); liberl/zeiss/bose followed the same shape
in `9a22b09`.

**Hosts in scope:**

| Host       | Type           | Impermanence | Enrollment key location on target                                          |
| ---------- | -------------- | ------------ | -------------------------------------------------------------------------- |
| erebonia   | NixOS host     | yes          | `/persist/var/lib/fleet-tls/enrollment.key`                                |
| roer       | microvm guest  | yes (parent) | `/persist/guests/roer/static/fleet-tls/enrollment.key` (on erebonia)       |
| saint-arkh | microvm guest  | yes (parent) | `/persist/guests/saint-arkh/static/fleet-tls/enrollment.key` (on erebonia) |
| trista     | incus VM guest | no           | `/var/lib/fleet-tls/enrollment.key` (on trista directly)                   |

**Pre-conditions:**

- `lib/common/data/pki/fleet_x5c_ca.crt` exists in repo (it does)
- `pki/fleet_x5c_ca_key` is in passage (used by `fleet-x5c-cert-sign`)
- `pki/ssh_host_ca_key` is in passage (already used; SSH host certs for
  erebonia/roer/saint-arkh/trista are already signed)
- basel's step-ca has the `fleet-x5c` provisioner active (it does —
  calvard hosts are using it)
- You can SSH to `root@erebonia` and `root@trista`
- Repo is clean / committed before starting

---

## Phase 1: Enroll the microvm guests (roer, saint-arkh)

`setup-guest.sh` handles this fully for microvm guests: it generates
the enrollment keypair (or reuses from passage), registers the pubkey
in `keys.json`, signs the X5C cert offline against the CA in passage,
stores the private key in passage, and scps the key onto the parent
into the static virtiofs share.

```bash
./scripts/setup-guest.sh erebonia roer       --target root@erebonia
./scripts/setup-guest.sh erebonia saint-arkh --target root@erebonia
```

After each run, verify:

- `lib/common/data/keys.json` has `fleetEnrollmentKeys.<guest>`
- `lib/common/data/fleet-x5c-certs/<guest>.crt` exists
- On erebonia: `/persist/guests/<guest>/static/fleet-tls/enrollment.key`
  exists, mode 600

---

## Phase 2: Enroll the incus guest (trista)

`setup-guest.sh` registers + signs for incus guests but does **not**
place files (no virtiofs share). Run the script first, then manually
scp the key to the running guest after Phase 4's rebuild creates the
`fleet-tls` group on it.

### 2.1 Register and sign

```bash
./scripts/setup-guest.sh erebonia trista
```

This generates the keypair, registers the pubkey in `keys.json`, signs
the X5C cert, and stores the key in passage. No file deployment.

Verify:

- `lib/common/data/keys.json` has `fleetEnrollmentKeys.trista`
- `lib/common/data/fleet-x5c-certs/trista.crt` exists

(Defer the actual key placement on trista to Phase 4.2 — the
`fleet-tls` group must exist first, which the rebuild creates.)

---

## Phase 3: Enroll erebonia (the parent host itself)

There's no script for in-place parent enrollment (deploy-nixos-anywhere
handles this only for fresh installs, via `--extra-files`). Do the
equivalent manually.

### 3.1 Generate the enrollment keypair

```bash
TMP=$(mktemp -d)
openssl genpkey -algorithm ED25519 -out "$TMP/enrollment.key"
openssl pkey -in "$TMP/enrollment.key" -pubout -out "$TMP/enrollment.pub"
chmod 600 "$TMP/enrollment.key"
```

### 3.2 Store the private key in passage

```bash
passage insert -m -f hosts/erebonia/fleet_enrollment_key < "$TMP/enrollment.key"
```

### 3.3 Register the pubkey in `keys.json`

```bash
PUB_PEM=$(cat "$TMP/enrollment.pub")
jq --arg name erebonia --arg key "$PUB_PEM" \
  '.fleetEnrollmentKeys[$name] = $key' \
  lib/common/data/keys.json > lib/common/data/keys.json.tmp \
  && mv lib/common/data/keys.json.tmp lib/common/data/keys.json
```

### 3.4 Sign the X5C cert offline

```bash
nix run .#fleet-x5c-cert-sign -- --sign erebonia
```

The signing app pulls `pki/fleet_x5c_ca_key` from passage and writes
`lib/common/data/fleet-x5c-certs/erebonia.crt`.

### 3.5 Place the enrollment key on erebonia

erebonia uses impermanence; the key has to live under `/persist/` so
it survives rollback. The fluent-bit module's `environment.persistence`
declares `/var/lib/fleet-tls` as a persisted dir owned by
`root:fleet-tls` mode `0750` — but that bind mount only activates
after Phase 4's rebuild. Pre-create the persist dir and put the key
there now; the rebuild will bind-mount it into place.

```bash
ssh root@erebonia 'mkdir -p /persist/var/lib/fleet-tls && chmod 0750 /persist/var/lib/fleet-tls'
scp "$TMP/enrollment.key" root@erebonia:/persist/var/lib/fleet-tls/enrollment.key
scp "$TMP/enrollment.pub" root@erebonia:/persist/var/lib/fleet-tls/enrollment.pub
ssh root@erebonia 'chmod 600 /persist/var/lib/fleet-tls/enrollment.key && chmod 644 /persist/var/lib/fleet-tls/enrollment.pub'
rm -rf "$TMP"
```

(Group ownership is set after the rebuild creates the `fleet-tls`
group — see 4.1.4.)

---

## Phase 4: Commit + Rebuild

### 4.1 Commit and rebuild erebonia

Stage everything generated in Phases 1–3:

```bash
git add lib/common/data/keys.json \
        lib/common/data/fleet-x5c-certs/{erebonia,roer,saint-arkh,trista}.crt \
        lib/common/data/pki/fleet_x5c_ca.srl
git status   # sanity check — should be just keys.json + 4 certs + the .srl
git commit -m "fleet: enroll erebonia and guests"
git push
```

#### 4.1.1 Pull on erebonia and rebuild

```bash
ssh root@erebonia 'cd /etc/nixos && git pull && nixos-rebuild switch --flake .#erebonia'
```

This rebuild will:

- Create the `fleet-tls` group on erebonia
- Bind-mount `/persist/var/lib/fleet-tls` → `/var/lib/fleet-tls`
- Deploy `/etc/fleet-tls/enrollment.crt` (signed cert from repo)
- `fleet-enrollment-key.service` skips on erebonia (key already
  visible at `/var/lib/fleet-tls/enrollment.key` via the bind mount —
  `ConditionPathExists=!` triggers skip)
- `fleet-tls-bootstrap.service` runs against basel and writes
  `/var/lib/fleet-tls/client.crt` + `client.key`
- `fluent-bit` starts and connects to tharbad

The rebuild also rebuilds and restarts the microvm guests roer and
saint-arkh with their new enrollment certs and the keys placed in
their static shares. Each guest's `fleet-enrollment-key.service`
copies from `/static/fleet-tls/enrollment.key` to
`/var/lib/fleet-tls/enrollment.key` on first boot, then bootstrap +
fluent-bit follow.

#### 4.1.2 Fix erebonia's enrollment key group ownership

The rebuild created the `fleet-tls` group; tighten ownership:

```bash
ssh root@erebonia 'chown root:fleet-tls /var/lib/fleet-tls/enrollment.key && chmod 640 /var/lib/fleet-tls/enrollment.key'
```

### 4.2 Place trista's enrollment key and rebuild trista

trista doesn't use impermanence, so the key lives directly at
`/var/lib/fleet-tls/enrollment.key`. Pull the key from passage and
push it to trista:

```bash
ssh root@trista 'mkdir -p /var/lib/fleet-tls && chmod 0750 /var/lib/fleet-tls'
passage show hosts/trista/fleet_enrollment_key | \
  ssh root@trista 'cat > /var/lib/fleet-tls/enrollment.key'
ssh root@trista 'chmod 600 /var/lib/fleet-tls/enrollment.key'
```

Now rebuild trista:

```bash
ssh root@trista 'cd /etc/nixos && git pull && nixos-rebuild switch --flake .#trista'
```

The rebuild creates the `fleet-tls` group, deploys
`/etc/fleet-tls/enrollment.crt`, and runs `fleet-tls-bootstrap`. The
`fleet-enrollment-key.service` on trista will fail/skip because there's
no `/static/fleet-tls/` (that's microvm-only) — but `ConditionPathExists`
on the unit means: it only runs when `/var/lib/fleet-tls/enrollment.key`
is **missing**. Since we placed it, the unit skips.

Tighten group ownership now that the group exists:

```bash
ssh root@trista 'chown root:fleet-tls /var/lib/fleet-tls/enrollment.key && chmod 640 /var/lib/fleet-tls/enrollment.key'
```

---

## Phase 5: Verification

### 5.1 Per-host sanity (erebonia, roer, saint-arkh, trista)

For each host:

```bash
ssh root@<host> '
  systemctl is-active fleet-tls-bootstrap fluent-bit
  ls -l /var/lib/fleet-tls/         # client.crt + client.key + enrollment.key/.pub
  ls -l /etc/fleet-tls/             # enrollment.crt
  step certificate inspect /var/lib/fleet-tls/client.crt --short
'
```

Expect `fleet-tls-bootstrap` = `active (exited)`, `fluent-bit` =
`active (running)`, and `client.crt` valid for ~365d signed by basel.

If `fleet-tls-bootstrap` is in `start-limit-hit` from earlier failed
attempts, reset and retry:

```bash
ssh root@<host> 'systemctl reset-failed fleet-tls-bootstrap fluent-bit && systemctl start fleet-tls-bootstrap'
```

### 5.2 End-to-end log/metric flow

On tharbad (or the Grafana frontend), confirm:

- Loki has new streams from `host=erebonia`, `host=roer`,
  `host=saint-arkh`, `host=trista` within ~30s of fluent-bit starting
- vmsingle has `up{instance="erebonia:..."}` etc. (or whatever the
  scrape labels are) appearing

### 5.3 Drift check

```bash
./scripts/check-cert-expiry.sh
```

Confirms all four new X5C certs are present, valid, and not in the
warn/fail window.

---

## Rollback

If a host's bootstrap fails and you can't get fluent-bit running:

- The fleet-tls failure does not block other services. fluent-bit is
  the only consumer of the bootstrapped cert.
- To temporarily skip: set `fluent-bit-agent.tls.certFile = null` in
  the host config (skips `hasTls` gate, which suppresses the X5C
  assertion and skips bootstrap entirely). Rebuild. Investigate.
- If the X5C cert was issued incorrectly, delete
  `lib/common/data/fleet-x5c-certs/<host>.crt`, fix the issue, re-run
  `nix run .#fleet-x5c-cert-sign -- --sign <host>`, commit, redeploy.
- If the on-host enrollment key is wrong (mismatch with the registered
  pubkey), delete `/var/lib/fleet-tls/enrollment.key` (and
  `client.{crt,key}`), pull the correct key from passage, place it,
  `systemctl reset-failed fleet-tls-bootstrap`, restart bootstrap.

---

## Post-deploy cleanup

Move this checklist to `llm-notes/done/` once Phase 5 passes for all
four hosts.
