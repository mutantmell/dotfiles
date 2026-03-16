# SSH Certificate Implementation Plan

## Context

Phases 1-2 of the SSH certificate rollout are complete: Keycloak is running on messeldam with a `homelab` realm, and step-ca is running on basel with an ACME provisioner. This plan implements phases 3-5: enabling SSH CA in step-ca, signing host certificates, configuring certificate-based SSH auth across all NixOS hosts, and client setup.

The goal is to eliminate TOFU for host verification and enable short-lived SSH user certificates authenticated via Keycloak OIDC, while keeping static SSH keys as a break-glass fallback.

---

## Step 1: Generate SSH CA Key Pairs (scripted)

**Script:** `nix run .#ssh-ca-bootstrap`

Generates user + host CA ed25519 key pairs, writes public keys into `lib/common/data/ssh-ca.json`, and copies private keys to `.keys/` (gitignored).

All SSH CA data lives in a single JSON file (`ssh-ca.json`), following the existing `keys.json` pattern:

```json
{
  "userCA": "ssh-ed25519 AAAA...",
  "hostCA": "ssh-ed25519 AAAA...",
  "hostCerts": {}
}
```

Currently, CA private keys live only in `.keys/` and are used locally by `ssh-cert-sign`. They are not deployed to any host. When step-ca integration is implemented (Step 3), the private keys will be encrypted as sops secrets on basel, where sops-nix decrypts them to `/run/secrets/` (tmpfs, memory-only). At that point the local `.keys/` copies can be removed.

Manual follow-up after running the script:

- Commit `ssh-ca.json`

---

## Step 2: Update Data Loader

**File:** `lib/common/data/default.nix`

Add SSH CA data from JSON with a `pathExists` guard:

```nix
sshCA = let
  path = ./ssh-ca.json;
in
  if builtins.pathExists path
  then builtins.fromJSON (builtins.readFile path)
  else null;
```

The guard means everything works before SSH CA is bootstrapped — `sshCA` is `null` until the JSON file exists. No separate files or `builtins.readDir` needed.

---

## Step 3: Enable SSH CA in step-ca

### 3a. Add secrets — `hosts/calvard/microvm/guests/basel/sops.nix`

Add to the `secrets` attrset:

```nix
"ssh_user_ca_key" = step-ca;
"ssh_host_ca_key" = step-ca;
```

### 3b. Configure SSH CA — `hosts/calvard/microvm/guests/basel/modules/step-ca.nix`

Add SSH key references to `settings`:

```nix
authority = {
  provisioners = [ /* existing ACME */ ];
  ssh = {
    hostKey = config.sops.secrets."ssh_host_ca_key".path;
    userKey = config.sops.secrets."ssh_user_ca_key".path;
  };
};
```

Add SSH user principal policy alongside existing `ssh.host`:

```nix
policy = {
  x509 = allowLocal;
  ssh.host = allowLocal;
  ssh.user = {
    allow = {
      principals = ["admin" "deploy"];
    };
  };
};
```

### 3c. Add egress rule — `hosts/calvard/microvm/guests/basel/default.nix`

Basel needs to reach messeldam for OIDC token validation:

```nix
{
  host = "messeldam";
  proto = "tcp";
  port = 443;
  comment = "OIDC token validation (Keycloak)";
}
```

### 3d. Expose step-ca SSH endpoints via nginx

Currently nginx only proxies `/acme`. Add a location for the SSH-related API paths. The simplest approach is to proxy all step-ca API paths:

```nix
locations."/" = {
  proxyPass = "https://127.0.0.1:9443/";
  extraConfig = /* same proxy_ssl config as /acme */;
};
```

Or more targeted: add `/ssh/`, `/sign/`, `/1.0/` locations with the same proxy config.

### 3e. Verification

```bash
# After deploying to basel:
step ssh roots --ca-url https://basel.internal
# Should return the SSH user and host CA public keys
```

---

## Step 4: Add OIDC Provisioner

### 4a. Keycloak client update — `hosts/calvard/microvm/guests/messeldam/modules/homelab-realm.json`

Change the `step-ca` client from `"publicClient": false` to `"publicClient": true`. This matches step-ca's standard OIDC provisioner pattern (authorization code flow via user's browser, redirect to `http://127.0.0.1:*`).

### 4b. Deploy Keycloak change to messeldam

### 4c. Add OIDC provisioner — `hosts/calvard/microvm/guests/basel/modules/step-ca.nix`

Add to `authority.provisioners`:

```nix
{
  type = "OIDC";
  name = "keycloak";
  clientID = "step-ca";
  configurationEndpoint = "https://auth.mutantmell.net/realms/homelab/.well-known/openid-configuration";
  listenAddress = "127.0.0.1:10000";
  claims = {
    enableSSHCA = true;
  };
  options = {
    ssh = {
      templateFile = "/etc/step-ca/templates/ssh/oidc.tpl";
    };
  };
}
```

### 4d. Create SSH certificate template

**File:** `hosts/calvard/microvm/guests/basel/modules/templates/oidc.tpl` (new)

Maps Keycloak `groups` claim to SSH certificate principals:

```json
{
  "type": {{ toJson .Type }},
  "keyId": {{ toJson .KeyID }},
  "principals": [{{ range $i, $g := .Token.groups }}{{ if $i }},{{ end }}{{ toJson $g }}{{ end }}],
  "extensions": {{ toJson .Extensions }}
}
```

Deploy via `environment.etc` in step-ca.nix:

```nix
environment.etc."step-ca/templates/ssh/oidc.tpl" = {
  source = ./templates/oidc.tpl;
  mode = "0444";
};
```

**Note on principal names:** Keycloak groups are `admins`, `deploy`, `media-users`. The template emits these as-is as certificate principals. The `AuthorizedPrincipalsFile` on target hosts must match these exact names. Alternatively, rename the Keycloak group `admins` -> `admin` for consistency with the existing plan docs.

### 4e. Verification

```bash
# From admin workstation:
step ssh login admin --provisioner keycloak --ca-url https://basel.internal
# Should open browser, authenticate via Keycloak, and write cert
```

---

## Step 5: Sign Host Certificates (scripted)

**Script:** `nix run .#ssh-cert-sign -- <hostname> <pubkey-path>`

The signing script queries `domainsForHost` from `lib/common/data/network.nix` to derive `--principal` flags automatically. No hardcoded host-to-principal mapping — principals stay in sync with the network registry.

```bash
# List all hosts and their principals (derived from network registry):
nix run .#ssh-cert-sign -- --list

# Sign a single host:
nix run .#ssh-cert-sign -- calvard /etc/ssh/ssh_host_ed25519_key.pub

# Backfill host public keys from live hosts into keys.json:
nix run .#ssh-cert-sign -- --backfill calvard
nix run .#ssh-cert-sign -- --backfill --guests-dir /data/guests remiferia

# Sign all hosts with registered public keys (non-interactive):
nix run .#ssh-cert-sign -- --all
```

### Host key locations

| Host type                                   | Key location                                                                 |
| ------------------------------------------- | ---------------------------------------------------------------------------- |
| MicroVM guests                              | `/static/etc/ssh/ssh_host_ed25519_key.pub` (on parent host's microVM volume) |
| Parent hosts (calvard, remiferia, erebonia) | `/etc/ssh/ssh_host_ed25519_key.pub`                                          |
| thebeyond                                   | `/etc/ssh/ssh_host_ed25519_key.pub`                                          |

### Host principals (derived from `domainsForHost`)

| Host      | Principals                                                                                                                |
| --------- | ------------------------------------------------------------------------------------------------------------------------- |
| basel     | `basel.internal.mutantmell.net`, `basel.internal`                                                                         |
| messeldam | `messeldam.internal.mutantmell.net`, `messeldam.internal`, `auth.mutantmell.net`                                          |
| langport  | `langport.internal.mutantmell.net`, `langport.internal`, `mutantmell.net`                                                 |
| creil     | `creil.internal.mutantmell.net`, `creil.internal`                                                                         |
| oracion   | `oracion.internal.mutantmell.net`, `oracion.internal`                                                                     |
| phantasma | `phantasma.internal.mutantmell.net`, `phantasma.internal`                                                                 |
| monrain   | `monrain.internal.mutantmell.net`, `monrain.internal`                                                                     |
| ardent    | `ardent.internal.mutantmell.net`, `ardent.internal`, `attic.ardent.internal.mutantmell.net`, `attic.ardent.internal`      |
| calvard   | `calvard.internal.mutantmell.net`, `calvard.internal`                                                                     |
| thebeyond | `thebeyond.internal.mutantmell.net`, `thebeyond.internal`, `internal.mutantmell.net`, `yggdrasil.internal.mutantmell.net` |
| remiferia | `remiferia.internal.mutantmell.net`, `remiferia.internal`, `jotunheimr.internal.mutantmell.net`                           |
| erebonia  | `erebonia.internal.mutantmell.net`, `erebonia.internal`                                                                   |

The signing script writes each certificate string into `ssh-ca.json` via `jq`. The `--list` subcommand also shows signed/unsigned status for each host.

---

## Step 6: Update openssh Module (smart defaults)

**File:** `modules/common/openssh.nix`

Add three new options with defaults that auto-discover from `ssh-ca.json` via the data loader:

```nix
hostCertificate = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  default = /* auto-discovered from hostname in sshCA.hostCerts */;
  description = "SSH host certificate string. Auto-discovered by hostname if available.";
};

trustedUserCA = lib.mkOption {
  type = lib.types.bool;
  default = /* true when sshCA.userCA exists */;
  description = "Trust the project SSH user CA for certificate authentication";
};

principals = lib.mkOption {
  type = lib.types.attrsOf (lib.types.listOf lib.types.str);
  default = { root = ["admin"]; };
  description = "Map of unix users to authorized SSH certificate principals";
};
```

Config section adds `extraConfig` directives and `environment.etc` entries using `text` (not `source`, since data comes from JSON strings):

- `HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub` (when cert exists)
- `TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub` (when CA key exists)
- `AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u` (when principals set)

All defaults gracefully degrade when `ssh-ca.json` doesn't exist yet (`sshCA` is `null`). Existing `authorizedKeys` logic stays as break-glass fallback.

---

## Step 7: Update Per-Host Configs

With smart defaults, **most hosts need no changes**. The module auto-discovers host certs by hostname and defaults to trusting the user CA.

Only hosts needing CI/CD deploy access require an override:

```nix
common.openssh.principals = { root = ["admin" "deploy"]; };
```

---

## Step 8: Client-Side Setup (manual)

### Trust host CA in known_hosts

Add to `~/.ssh/known_hosts`:

```
@cert-authority *.internal,*.internal.mutantmell.net ssh-ed25519 AAAA...<SSH_HOST_CA_PUBLIC_KEY>...
```

### SSH config

Add to `~/.ssh/config`:

```
Host *.internal *.internal.mutantmell.net
  User root
  IdentityFile ~/.ssh/id_ed25519
  CertificateFile ~/.ssh/id_ed25519-cert.pub
```

### Bootstrap step-cli trust

```bash
step ca bootstrap --ca-url https://basel.internal --fingerprint <ROOT_CA_FINGERPRINT>
```

### Login and test

```bash
step ssh login admin --provisioner keycloak
ssh root@calvard.internal
```

---

## Verification Checklist

1. `nix run .#ssh-cert-sign -- --list` — shows all hosts with correct principals from network registry
2. `step ssh roots --ca-url https://basel.internal` — returns SSH CA public keys
3. `step ssh login admin --provisioner keycloak` — browser auth via Keycloak works
4. `ssh -v root@calvard.internal` — verbose output shows "Server host certificate" verification
5. Static SSH keys still work (break-glass)
6. Principal-based access: `admin` group users can access all hosts; `deploy` group only where listed

---

## Scripts

### `nix run .#ssh-ca-bootstrap` — one-time CA setup

1. Generates user + host CA ed25519 key pairs
2. Creates `lib/common/data/ssh-ca.json` with CA public keys and empty `hostCerts`
3. Places private keys in `.keys/`
4. Prints sops commands for encrypting private keys into basel's secrets

Runtime deps: `git`, `openssh`, `jq`

### `nix run .#ssh-cert-sign` — host certificate signing

- `-- <hostname> <pubkey-path>` — sign one host, update `ssh-ca.json`
- `-- --all` — sign all hosts with registered public keys (non-interactive, reads from `keys.json` registry)
- `-- --list` — show all hosts with principals, signed/unsigned status, and pubkey registration status
- `-- --backfill [--guests-dir <path>] <parent-host>` — fetch host public keys via SSH and register in `keys.json`

Derives principals from `domainsForHost` in the network registry. Signs certs with `step ssh certificate`, then writes the cert string into `ssh-ca.json` via `jq`. Host public keys are stored in `keys.json` under `hostKeys`, populated by `--backfill` or automatically during `deploy-nixos-anywhere.sh`. Runtime deps: `git`, `step-cli`, `jq`, `nix`.

---

## Critical Files

| File                                                                | Change                                                                     |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `lib/common/data/ssh-ca.json`                                       | New — all SSH CA public keys and host certs (created/updated by scripts)   |
| `lib/common/data/default.nix`                                       | Add `sshCA` from JSON with `pathExists` guard                              |
| `hosts/calvard/microvm/guests/basel/sops.nix`                       | Add SSH CA private key secrets                                             |
| `hosts/calvard/microvm/guests/basel/modules/step-ca.nix`            | SSH CA config, OIDC provisioner, template                                  |
| `hosts/calvard/microvm/guests/basel/modules/templates/oidc.tpl`     | New — group-to-principal mapping                                           |
| `hosts/calvard/microvm/guests/basel/default.nix`                    | Egress rule to messeldam:443                                               |
| `hosts/calvard/microvm/guests/messeldam/modules/homelab-realm.json` | step-ca client -> publicClient                                             |
| `modules/common/openssh.nix`                                        | Add hostCertificate, trustedUserCA, principals options with smart defaults |
| `apps/ssh-ca-bootstrap.nix`                                         | New — CA key generation, writes JSON                                       |
| `apps/ssh-cert-sign.nix`                                            | New — host cert signing, updates JSON                                      |
| `apps/default.nix`                                                  | Register both new apps                                                     |
