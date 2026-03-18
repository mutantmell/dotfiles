# SSH Host Certificate Signing — Implementation Plan

## Context

User SSH certificates are working (step ssh login via Keycloak OIDC → step-ca). The final piece is **host certificate signing** — signing each host's SSH public key with the host CA so clients can verify host identity without TOFU. This requires:

1. A signing script that reads host keys from the registry and signs them
2. Deploying signed certificates to hosts via the existing NixOS openssh module
3. Client-side `@cert-authority` trust

Certificates are public data (like host public keys), so storing them in the repo is safe and lets NixOS deploy them declaratively via `environment.etc`.

---

## What We Implemented (and Why)

The original plan used a step-ca JWK provisioner to sign host certificates via the step-ca API. During implementation, we simplified to **direct `ssh-keygen -s` signing** with the existing SSH host CA private key. This eliminated significant complexity:

**Removed:**

- JWK provisioner bootstrap script and key files
- JWK encrypted private key + password (a second secret management mechanism alongside sops)
- step-ca configuration changes (provisioner, host template, sops secret)
- Network dependency on step-ca being reachable during signing
- Basel deploy as a prerequisite for signing

**Why this is better for our use case:**

- Host certs are long-lived static data committed to git — they fit NixOS's declarative model naturally
- The SSH host CA key already exists in `.keys/` from the original CA bootstrap
- `ssh-keygen -s -h` inherently produces host certs (no template needed to enforce type)
- Single secret mechanism: the CA key lives in `.keys/` for operator use and in sops for step-ca's runtime
- The signing script is a rare one-off operation, not an operationalized service

---

## Phase 1: Host Certificate Signing Script

**Goal:** Create an app that signs host public keys using `ssh-keygen -s`.

### `apps/ssh-host-cert-sign.nix`

Following the `ssh-key-registry.nix` pattern. The script:

1. Reads host public keys from `keys.json` → `hostKeys`
2. Gets principals from `allHostDomains` via nix eval
3. For each host, writes the pubkey to a temp file and signs with `ssh-keygen -s`
4. Writes certificates to `lib/common/data/host-certs/<hostname>-cert.pub`

**Subcommands:**

- `--sign-all [--ca-key <path>]` — sign all hosts with registered keys
- `--sign <hostname> [--ca-key <path>]` — sign a single host
- `--list` — show hosts with key/cert status and cert expiry
- (no args) — usage help

**Signing flow per host:**

```bash
ssh-keygen -s "$CA_KEY" -I "$hostname" -h -n "$principals" -V "+5y" -z "$(date +%s)" "$tmpdir/$hostname.pub"
mv "$tmpdir/$hostname-cert.pub" "$CERTS_DIR/$hostname-cert.pub"
```

**Defaults:**

- `--ca-key`: `.keys/ssh_host_ca_key`

**Runtime deps:** `openssh`, `jq`, `nix`, `git`

### Register in `apps/default.nix`

```nix
ssh-host-cert-sign = import ./ssh-host-cert-sign.nix {inherit pkgs;};
```

---

## Phase 2: Certificate Deployment via NixOS

**Goal:** Configure sshd on all hosts to present their host certificate.

### `lib/common/data/host-certs/` directory

Start with `.gitkeep`. Populated by the signing script.

### `lib/common/data/default.nix` — `hostCerts` lookup

Auto-discovers `<hostname>-cert.pub` files in the `host-certs/` directory:

```nix
hostCerts = let
  certDir = ./host-certs;
  certFiles = if builtins.pathExists certDir then builtins.readDir certDir else {};
  parseName = filename:
    let m = builtins.match "(.+)-cert\\.pub" filename;
    in if m != null then builtins.head m else null;
in lib.listToAttrs (lib.filter (x: x != null)
  (lib.mapAttrsToList (filename: _:
    let hostname = parseName filename;
    in if hostname != null
      then { name = hostname; value = certDir + "/${filename}"; }
      else null
  ) certFiles));
```

### `modules/common/openssh.nix` — HostCertificate support

New option `hostCertificate` (default: true). When enabled and a cert exists for the host, deploys it via `environment.etc` and adds `HostCertificate` to sshd config.

Since certificates are deployed via `environment.etc` (Nix store → symlink), they don't need impermanence configuration.

---

## Phase 3: Client-Side Setup (Manual)

Add to `~/.ssh/known_hosts`:

```
@cert-authority *.internal,*.internal.mutantmell.net,*.mutantmell.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILgffMg8KN4MSc+nencNM8xUK+UVeNCM9WsnVPakJkuO ssh-host-ca@mutantmell.net
```

The signing script prints this line after a successful run.

---

## Implementation Sequence

1. Create `lib/common/data/host-certs/` with `.gitkeep`
2. Add `hostCerts` to `lib/common/data/default.nix`
3. Update `modules/common/openssh.nix` with host certificate deployment
4. Create `apps/ssh-host-cert-sign.nix` + register in `apps/default.nix`
5. **Backfill host keys**: `nix run .#ssh-key-registry -- --backfill calvard` (and other parent hosts)
6. **Sign all hosts**: `nix run .#ssh-host-cert-sign -- --sign-all`
7. Commit signed certificates
8. **Deploy all hosts** — sshd now presents host certificates
9. **Client setup** — add `@cert-authority` to `~/.ssh/known_hosts`

---

## Verification

1. After signing: `ssh-keygen -L -f lib/common/data/host-certs/<host>-cert.pub` shows correct principals and validity
2. After deploy: `ssh -o StrictHostKeyChecking=yes root@<host>.internal` succeeds without TOFU prompt (after adding `@cert-authority` to known_hosts)
3. Static SSH key auth still works (break-glass fallback)

---

## Files Modified/Created

| File                          | Change                                                 |
| ----------------------------- | ------------------------------------------------------ |
| `apps/ssh-host-cert-sign.nix` | **New** — host certificate signing script              |
| `apps/default.nix`            | Register signing app                                   |
| `lib/common/data/default.nix` | Add `hostCerts` auto-discovery                         |
| `lib/common/data/host-certs/` | **New dir** — signed host certificates                 |
| `modules/common/openssh.nix`  | `hostCertificate` option + HostCertificate sshd config |

---

## Future: Hybrid Static/Dynamic Setup

The static `ssh-keygen -s` approach works well for long-lived hosts managed by NixOS. If we ever need dynamic host certificates (e.g., ephemeral VMs, short-lived containers, auto-rotation), we could layer a step-ca JWK provisioner on top without replacing the static layer:

### What would be needed

1. **JWK provisioner on step-ca** — A JWK key pair for programmatic signing. The encrypted private key would be checked into the repo (it's password-protected), and the password stored in sops for basel. A host certificate template (`type: host`) would restrict the provisioner to host certs only.

2. **On-host certificate renewal service** — A systemd timer/service on each host that periodically requests a new host certificate from step-ca using the JWK provisioner. This would need the JWK password available at runtime (via sops) and the step-ca CA URL.

3. **Impermanence considerations** — Dynamically-issued certs would need to persist across reboots (unlike static certs which are rebuilt from the Nix store). The cert file path would need an impermanence entry, or the renewal service would need to run early enough in boot.

4. **Fallback chain** — Hosts could present the static cert (from git/NixOS) as a baseline, with the dynamic cert overriding it when available. This ensures hosts are always verifiable even if step-ca is unreachable.

5. **Policy decisions** — Cert lifetime (short-lived certs need reliable renewal), revocation strategy, and whether step-ca's audit trail justifies the added complexity for the specific hosts that need dynamic certs.

### When to consider this

- Hosts that are created/destroyed frequently (not managed by NixOS rebuilds)
- Requirement for short-lived certificates with automatic rotation
- Need for centralized audit trail of certificate issuance
- Hosts that generate their own keys at boot (no pre-registered key in `keys.json`)
