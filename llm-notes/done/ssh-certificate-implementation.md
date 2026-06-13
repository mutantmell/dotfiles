# SSH Certificate Implementation Plan

**Status:** COMPLETE. This is a historical rollout record. References to
Keycloak describe the original implementation; the active OIDC provider is
Authelia on messeldam with lldap-backed users/groups.

## Context

Phases 1-2 of the SSH certificate rollout are complete: Keycloak is running on messeldam with a `homelab` realm, and step-ca is running on basel with an ACME provisioner. This plan implements SSH user certificate authentication via Keycloak OIDC, with host certificate signing as a follow-up.

The goal is to enable short-lived SSH user certificates authenticated via Keycloak OIDC, while keeping static SSH keys as a break-glass fallback. Host certificate signing (eliminating TOFU) is a separate follow-up once step-ca is running with SSH CA support.

## Current state

Already implemented:

- **Step 1 complete** — CA key pairs generated, public keys committed to `lib/common/data/pki/`
- **Step 5 groundwork complete** — `trustedUserCA` defaults to `true`, principals configured. Safe to deploy before step-ca is issuing certificates: `TrustedUserCAKeys` and `AuthorizedPrincipalsFile` are inert until certificates are actually presented. Static SSH key auth is unaffected.
- `modules/common/openssh.nix` — `trustedUserCA` (default `true`) and `principals` options
- `lib/common/data/default.nix` — `pki.sshUserCA` and `pki.sshHostCA` (direct paths, keys always present)
- `apps/ssh-ca-bootstrap.nix` — generates CA key pairs, writes public keys to `pki/`, saves private keys to `.keys/`, prints sops key names and paths
- `apps/ssh-key-registry.nix` — `--backfill` fetches host public keys via SSH into `keys.json`, `--list` shows registration status
- `scripts/deploy-nixos-anywhere.sh` — automatically registers host public keys in `keys.json` during deployment
- `lib/common/data/keys.json` — `hostKeys` section for host public key registry

---

## Step 1: Generate SSH CA Key Pairs

```bash
nix run .#ssh-ca-bootstrap
```

Generates user + host CA ed25519 key pairs, writes public keys to `lib/common/data/pki/ssh_user_ca.pub` and `ssh_host_ca.pub`.

The script saves private keys to `.keys/` (gitignored) and prints the sops key names and file path needed to encrypt them into basel's secrets.

Manual follow-up:

- Encrypt private keys into basel's sops secrets (key names and paths printed by the script)
- Commit the public keys: `git add lib/common/data/pki/ssh_user_ca.pub lib/common/data/pki/ssh_host_ca.pub`

**Status: Complete.**

---

## Step 2: Enable SSH CA in step-ca

### 2a. Add secrets — `hosts/calvard/microvm/guests/basel/sops.nix`

Add to the `secrets` attrset:

```nix
"ssh_user_ca_key" = step-ca;
"ssh_host_ca_key" = step-ca;
```

### 2b. Configure SSH CA — `hosts/calvard/microvm/guests/basel/modules/step-ca.nix`

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

### 2c. Add egress rule — `hosts/calvard/microvm/guests/basel/default.nix`

Basel needs to reach messeldam for OIDC token validation:

```nix
{
  host = "messeldam";
  proto = "tcp";
  port = 443;
  comment = "OIDC token validation (Keycloak)";
}
```

### 2d. Expose step-ca SSH endpoints via nginx

Currently nginx only proxies `/acme`. Add a location for the SSH-related API paths. The simplest approach is to proxy all step-ca API paths:

```nix
locations."/" = {
  proxyPass = "https://127.0.0.1:9443/";
  extraConfig = /* same proxy_ssl config as /acme */;
};
```

Or more targeted: add `/ssh/`, `/sign/`, `/1.0/` locations with the same proxy config.

---

## Step 3: Add OIDC Provisioner

### 3a. Keycloak client update — `hosts/calvard/microvm/guests/messeldam/modules/homelab-realm.json`

Change the `step-ca` client from `"publicClient": false` to `"publicClient": true`. This matches step-ca's standard OIDC provisioner pattern (authorization code flow via user's browser, redirect to `http://127.0.0.1:*`).

### 3b. Add OIDC provisioner — `hosts/calvard/microvm/guests/basel/modules/step-ca.nix`

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

### 3c. Create SSH certificate template

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

---

## Step 4: Deploy and verify

Deploy messeldam (Keycloak publicClient change) and basel (step-ca SSH CA + OIDC provisioner).

```bash
# Verify step-ca SSH CA is serving:
step ssh roots --ca-url https://basel.internal
# Should return the SSH user and host CA public keys
```

---

## Step 5: Deploy all hosts

Deploying picks up the openssh module changes — `TrustedUserCAKeys` and `AuthorizedPrincipalsFile` are now configured on every host with `common.openssh.enable = true`. Static SSH key auth continues to work as a break-glass fallback.

Only hosts needing CI/CD deploy access require a per-host override:

```nix
common.openssh.principals = { root = ["admin" "deploy"]; };
```

---

## Step 6: Client-side setup (manual, one-time)

### Trust host CA in known_hosts

Add to `~/.ssh/known_hosts` (from `lib/common/data/pki/ssh_host_ca.pub`):

```
@cert-authority *.internal,*.internal.mutantmell.net ssh-ed25519 AAAA...<SSH_HOST_CA_PUBLIC_KEY>...
```

This is only useful once host certificates are signed (follow-up work), but is harmless to add now.

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
ssh root@edith.internal
```

---

## Follow-up: Host certificate signing

Once step-ca is running with SSH CA support, host certificates can be signed to eliminate TOFU. This involves:

1. Signing host public keys via step-ca's SSH API (using keys from the `hostKeys` registry in `keys.json`, populated by `nix run .#ssh-key-registry -- --backfill` or automatically during `deploy-nixos-anywhere.sh`)
2. Placing signed certificates on hosts at `/etc/ssh/ssh_host_ed25519_key-cert.pub` (sshd picks these up by convention)
3. Clients verify host identity via the `@cert-authority` line in `known_hosts`

The exact signing mechanism (script, step-ca API calls, or host auto-renewal) can be designed once step-ca is running and the API can be tested directly.

### Host key locations

| Host type                                              | Key location                                                                  |
| ------------------------------------------------------ | ----------------------------------------------------------------------------- |
| MicroVM guests                                         | `<guests-dir>/<guest>/static/etc/ssh/ssh_host_ed25519_key.pub` on parent host |
| Incus guests                                           | `<guests-dir>/<guest>/static/etc/ssh/ssh_host_ed25519_key.pub` on parent host |
| Parent hosts (calvard, remiferia, erebonia, thebeyond) | `/etc/ssh/ssh_host_ed25519_key.pub`                                           |

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

---

## Verification Checklist

1. `step ssh roots --ca-url https://basel.internal` — returns SSH CA public keys
2. `step ssh login admin --provisioner keycloak` — browser auth via Keycloak works
3. `ssh root@edith.internal` — authenticates with user certificate
4. Static SSH keys still work (break-glass fallback)
5. Principal-based access: `admin` group users can access all hosts; `deploy` group only where listed

---

## Scripts

### `nix run .#ssh-ca-bootstrap` — one-time CA setup

1. Generates user + host CA ed25519 key pairs
2. Writes public keys to `lib/common/data/pki/`
3. Saves private keys to `.keys/` (gitignored)
4. Prints sops key names and paths for encrypting private keys into basel's secrets

Runtime deps: `git`, `openssh`

### `nix run .#ssh-key-registry` — host public key registry

- `-- --list` — show all hosts with pubkey registration status and domains
- `-- --backfill [--guests-dir <path>] <parent-host>` — fetch host public keys via SSH and register in `keys.json`

Discovers guests from the local repo structure (`hosts/<parent>/microvm/guests/` and `hosts/<parent>/incus/guests/`), filtered to only hosts present in the network registry. Runtime deps: `git`, `jq`, `nix`, `ssh`

---

## Critical Files

| File                                                                | Change                                                         |
| ------------------------------------------------------------------- | -------------------------------------------------------------- |
| `lib/common/data/pki/ssh_user_ca.pub`                               | New — SSH user CA public key (created by bootstrap)            |
| `lib/common/data/pki/ssh_host_ca.pub`                               | New — SSH host CA public key (created by bootstrap)            |
| `lib/common/data/default.nix`                                       | `pki.sshUserCA` and `pki.sshHostCA` (direct paths)             |
| `lib/common/data/keys.json`                                         | `hostKeys` section for host public key registry                |
| `hosts/calvard/microvm/guests/basel/sops.nix`                       | Add SSH CA private key secrets                                 |
| `hosts/calvard/microvm/guests/basel/modules/step-ca.nix`            | SSH CA config, OIDC provisioner, template                      |
| `hosts/calvard/microvm/guests/basel/modules/templates/oidc.tpl`     | New — group-to-principal mapping                               |
| `hosts/calvard/microvm/guests/basel/default.nix`                    | Egress rule to messeldam:443                                   |
| `hosts/calvard/microvm/guests/messeldam/modules/homelab-realm.json` | step-ca client -> publicClient                                 |
| `modules/common/openssh.nix`                                        | `trustedUserCA` (default `true`) and `principals` options      |
| `apps/ssh-ca-bootstrap.nix`                                         | CA key generation, public keys to pki/, private keys to .keys/ |
| `apps/ssh-key-registry.nix`                                         | Host public key backfill and listing                           |
| `apps/default.nix`                                                  | Register both apps                                             |
| `scripts/deploy-nixos-anywhere.sh`                                  | Auto-register host public keys during deployment               |
