# Keycloak OAuth2 / OIDC Integration Plan

> **Status:** Planning. This plan describes the target architecture, not the current
> deployment. Service placement reflects the intended state after the
> [vMGMT/vINFRA split](./secure-mgmt-vlan-plan.md) and related refactors.

## Goals

1. **OAuth2 provider for step-ca** — Keycloak issues OIDC tokens that step-ca uses to
   sign short-lived SSH certificates (covered by [ssh-certificates-sso-plan](./ssh-certificates-sso-plan.md),
   listed here for completeness).
2. **Web traffic gating for vDMZ** — oauth2-proxy on surtr gates all inbound web traffic
   arriving via WireGuard from a cloud host. Users must authenticate through Keycloak
   before reaching backend services.
3. **OIDC integration for services** — Services that support OIDC natively (e.g. Grafana,
   Gitea, HomeAssistant) authenticate directly against Keycloak without going through
   oauth2-proxy.
4. **Dynamic user accounts** — Keycloak is the central user directory. Accounts are managed
   at runtime via the admin console or API, not in NixOS configuration (no credentials in
   a public repo).

## Target Service Placement

| Component | Host | Network | Notes |
|-----------|------|---------|-------|
| Keycloak | dedicated microvm | vINFRA | OIDC provider, user directory |
| step-ca | dedicated microvm | vINFRA | SSH CA + ACME CA, isolated key material |
| oauth2-proxy | surtr | vDMZ | Web traffic gating |
| nginx (Keycloak + ACME proxy) | Keycloak microvm | vINFRA | Reverse proxy for Keycloak + ACME passthrough to step-ca |
| nginx (OAuth-gated Adguard) | alfheim | vINFRA | Admin UI with auth_request to surtr |

### What exists in Keycloak today

- An `external` realm with an `oauth2-proxy` client (referenced by surtr's config)
- Keycloak accessible at `https://gridr.local/auth`
- OIDC issuer URL: `https://gridr.local/auth/realms/external`

### What this plan addresses

- Keycloak and step-ca placement on vINFRA (dedicated microvms)
- OIDC provisioner on step-ca for SSH certificate issuance
- Declarative realm/client configuration (currently manual)
- Group/role structure for access control
- Cross-VLAN firewall rules (vDMZ → Keycloak on vINFRA)
- External access architecture (cloud host → WireGuard → oauth2-proxy → Keycloak)
- ACME endpoint reachability for vDMZ hosts
- Keycloak microvm resource sizing

---

## Hosting Decision

### Keycloak: dedicated microvm on vINFRA

Keycloak is infrastructure. It's the identity provider for the entire network — every
service that authenticates users depends on it. This puts it in the same category as DNS
(alfheim), NTP (yggdrasil), and step-ca: foundational services that belong on the
management plane.

| Consideration | vHOME | vINFRA |
|---------------|-------|--------|
| Role classification | User devices, media, home automation | Infrastructure services (DNS, NTP, CA) |
| step-ca → Keycloak (OIDC) | Cross-zone (management → trusted) | Intra-zone (management → management) |
| alfheim → Keycloak | Cross-zone (management → trusted) | Intra-zone (management → management) |
| User browsers → Keycloak | Intra-zone (trusted → trusted) | Cross-zone (trusted → management, allowed by `accessTo`) |
| Can be reached from vDMZ | Needs explicit rule | Needs explicit rule |
| Internet access | Unfiltered | Filtered (HTTP/HTTPS/DNS/NTP — sufficient for Keycloak) |

Both zones require an explicit firewall rule for vDMZ access, so that's a wash. The
deciding factor is that vINFRA consolidates auth infrastructure: step-ca → Keycloak and
alfheim → Keycloak become intra-zone traffic. The OIDC provisioner connection (step-ca →
Keycloak for token validation) is the most security-sensitive path, and keeping it within
the management zone is cleaner than routing it across zones.

The "user-facing" argument for vHOME doesn't hold up. DNS is equally user-facing — every
device on every VLAN queries alfheim — yet it belongs on vINFRA. The question is what role
the service plays, not who talks to it.

### step-ca: dedicated microvm on vINFRA

step-ca moves to its own microvm on vINFRA, as specified in the
[SSH certificates plan](./ssh-certificates-sso-plan.md). A dedicated microvm provides
isolation for CA key material. step-ca and Keycloak are on separate microvms despite being
on the same zone — Keycloak runs a JVM + PostgreSQL with significant attack surface, while
step-ca is a minimal Go binary holding the CA root key.

### ACME proxy on the Keycloak microvm

The Keycloak microvm runs nginx to reverse-proxy Keycloak (at `/auth`) and already needs
TLS termination. Adding an `/acme` location that proxies to step-ca is natural:

```
vDMZ host → Keycloak microvm (vINFRA, /acme) → step-ca (vINFRA, :9443/acme)
```

Since both are on vINFRA, the proxy-to-step-ca path is intra-zone — no firewall rules
needed. vDMZ hosts reach the Keycloak microvm via the single explicit firewall rule
(see [Cross-VLAN Firewall Requirements](#cross-vlan-firewall-requirements)), which covers
both OIDC and ACME. vHOME and vINFRA hosts can reach step-ca directly or via the proxy.

### Microvm sizing

| Microvm | vCPU | RAM | Persistent Storage | Services |
|---------|------|-----|-------------------|----------|
| Keycloak | 2 | 2048MB | ~100GB (PostgreSQL) | Keycloak, PostgreSQL, nginx |
| step-ca | 1 | 512MB | Small (badger DB, CA keys) | step-ca |

step-ca's persistent storage holds the CA root key material and the badger database.
This data is critical — loss means re-provisioning all certificates. Back up alongside
other infrastructure secrets.

### Architecture diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ vINFRA (management zone)                                        │
│                                                                 │
│   Keycloak microvm                                              │
│     ├── Keycloak (OIDC provider)                                │
│     └── nginx                                                   │
│           ├── /auth → Keycloak (:9080)                          │
│           └── /acme → step-ca (intra-zone, :9443)               │
│                 ↑                                                │
│   step-ca microvm                                               │
│     └── step-ca (OIDC provisioner validates against Keycloak)   │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ vHOME (trusted zone)                                            │
│   User browsers → Keycloak (trusted → management, allowed)     │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ vDMZ (untrusted zone)                       [explicit FW rule]  │
│   surtr ────→ Keycloak microvm (OIDC + ACME)                    │
│     ├── oauth2-proxy (OIDC tokens from Keycloak)                │
│     ├── nginx (/auth proxies Keycloak for external users)       │
│     └── nginx (/ proxies to backend services)                   │
│   bragi, hrungnir (ACME certs via Keycloak microvm /acme proxy) │
└─────────────────────────────────────────────────────────────────┘
```

### Update to SSH certificates plan

The SSH certificates plan should be updated to reflect:
1. Keycloak moves to a dedicated vINFRA microvm (not "a vINFRA host" generically,
   and not vHOME)
2. step-ca moves to a dedicated vINFRA microvm (updated to say vINFRA rather than
   vMGMT, since vMGMT becomes the locked-down networking gear zone after the split)
3. Reference the `homelab` realm and `step-ca` client defined in this plan

---

## Realm and Client Architecture

### Single realm: `homelab`

Use one realm for all services. The current `external` realm should be renamed to `homelab`
(or a new realm created and `external` retired). Multiple realms add user management
overhead without meaningful security benefit in a homelab context — group-based access
control within a single realm provides the same granularity.

> **Note:** Renaming a Keycloak realm requires creating a new one and migrating clients
> and users. Since the current `external` realm has minimal configuration, creating a fresh
> `homelab` realm and reconfiguring clients is simpler than migration.

### Clients

Each service that authenticates against Keycloak needs a registered client:

| Client ID | Type | Grant Types | Purpose | Redirect URIs |
|-----------|------|-------------|---------|---------------|
| `oauth2-proxy` | Confidential | Authorization Code | Web traffic gating (surtr) | `https://surtr.local/oauth2/callback`, `https://<external-domain>/oauth2/callback` |
| `step-ca` | Confidential | Authorization Code | SSH certificate issuance (interactive) | `http://127.0.0.1:*` (localhost callback for `step ssh login`) |
| `cicd-deploy` | Confidential | Client Credentials | CI/CD machine-to-machine auth | N/A (no browser redirect) |
| `adguard-proxy` | (uses oauth2-proxy) | — | Alfheim admin UI protection | Shares `oauth2-proxy` client |

Additional clients added per-service as OIDC integrations are enabled (see
[OIDC Integrations](#oidc-integrations) below).

**Client secrets** are stored in sops-nix on the hosts that need them:
- `oauth2-proxy` secret → surtr's sops secrets
- `step-ca` OIDC provisioner secret → step-ca microvm's sops secrets
- `cicd-deploy` secret → CI/CD server's environment (encrypted at rest)

### Groups and roles

Groups control access across services. Keycloak groups can be mapped to:
- oauth2-proxy's `--allowed-groups` (restrict which users can access web services)
- step-ca SSH certificate principals (map groups → SSH principals)
- Per-service OIDC claims (service-specific role mapping)

| Group | Purpose | SSH Principal | Web Access |
|-------|---------|---------------|------------|
| `admins` | Full access to everything | `admin` | All services |
| `media-users` | Jellyfin and media services | — | Media services only |
| `deploy` | CI/CD service accounts | `deploy` | — |

Group membership is managed dynamically via the Keycloak admin console. The group
*structure* (names, role mappings, protocol mappers) can be managed declaratively
(see [Static vs Dynamic Configuration](#static-vs-dynamic-configuration)).

### Authentication policies

Configure at the realm level:
- **MFA required for admins:** Conditional OTP or WebAuthn for the `admins` group
- **Password policy:** Minimum length, no reuse (realm-level setting)
- **Session timeouts:** Access token lifetime 5min, refresh token 30min, SSO session 12h
- **Brute force protection:** Enabled (Keycloak built-in)

---

## Cross-VLAN Firewall Requirements

After the [zone-based firewall refactor](./zone-refactor-plan.md), the forwarding model is:

- `trusted` (vHOME) → `untrusted` (vDMZ): **allowed** (via `accessTo`)
- `untrusted` (vDMZ) → `trusted` (vHOME): **blocked** (not in `accessTo`)
- `management` (vINFRA) → `untrusted` (vDMZ): **allowed**
- `isolated` (wg-ba) → anything: **blocked** (except via `extraForwardRules`)

### Required firewall rules

The OAuth2/OIDC flow requires these cross-VLAN connections that are not covered by
zone-level `accessTo`:

| Source | Destination | Port | Purpose | Status |
|--------|-------------|------|---------|--------|
| surtr (vDMZ) | Keycloak microvm (vINFRA) | 443 | oauth2-proxy → Keycloak OIDC | **Needs explicit rule** |
| vDMZ ACME clients | Keycloak microvm (vINFRA) | 443 | ACME cert issuance (proxied to step-ca) | **Needs explicit rule** (same as above) |
| step-ca (vINFRA) | Keycloak microvm (vINFRA) | 443 | OIDC provisioner → Keycloak token validation | Intra-zone (management → management) |
| Keycloak microvm (vINFRA) | step-ca (vINFRA) | 9443 | ACME proxy → step-ca | Intra-zone (management → management) |
| alfheim (vINFRA) | surtr (vDMZ) | 443 | nginx auth_request → oauth2-proxy | Allowed (management → untrusted) |
| alfheim (vINFRA) | Keycloak microvm (vINFRA) | 443 | Direct Keycloak access | Intra-zone (management → management) |
| User browsers (vHOME) | Keycloak microvm (vINFRA) | 443 | OAuth login page | Allowed (trusted → management) |
| wg-ba peers | surtr (vDMZ) | 443 | External web traffic | Already in extraForwardRules |

Only the first row requires a new explicit firewall rule. All intra-zone paths (step-ca,
alfheim, ACME proxy) work without rules. User browsers on vHOME reach Keycloak via the
existing `trusted` → `management` `accessTo` rule. The vDMZ ACME clients (surtr, bragi,
hrungnir) reach step-ca's ACME endpoint through the Keycloak microvm's `/acme` proxy, so
they use the same firewall rule as OIDC.

**Implementation** — add to `extraForwardRules` on yggdrasil:

```nix
firewall.extraForwardRules = [
  # Existing rules
  { iifname = "vDMZ.br0"; oifname = "wg-ba"; verdict = "accept"; }
  { iifname = "wg-ba"; ip.daddr = "10.0.100.40"; verdict = "accept"; }

  # vDMZ hosts need to reach the Keycloak microvm on vINFRA for:
  #   - oauth2-proxy OIDC token exchange (surtr)
  #   - ACME certificate issuance via /acme proxy (surtr, bragi, hrungnir)
  {
    iifname = "vDMZ.br0";
    oifname = "vINFRA.br0";
    ip.daddr = "<keycloak-microvm-ip>";
    tcp.dport = 443;
    verdict = "accept";
    comment = "vDMZ -> Keycloak microvm (OIDC + ACME proxy)";
  }
];
```

This allows any vDMZ host to reach the Keycloak microvm on port 443 (needed for both OIDC
and ACME). It could be further narrowed to specific source IPs if desired, but all vDMZ
hosts with ACME certificates need this path.

**Note on alfheim → surtr:** alfheim proxies OAuth requests to surtr
(`https://surtr.local/oauth2/`). Both alfheim and surtr are reachable via zone-level
`accessTo` (management → untrusted) — no extra rule needed.

### ACME proxy on the Keycloak microvm

The Keycloak microvm's nginx proxies `/acme` to step-ca. Since both microvms are on
vINFRA, this is intra-zone traffic:

```nix
# On the Keycloak microvm
locations."/acme" = {
  proxyPass = "https://<step-ca-host>.local:9443/acme";
  extraConfig = ''
    proxy_ssl_certificate /etc/nginx/nginx.cert;
    proxy_ssl_certificate_key /etc/nginx/nginx.key;
    proxy_ssl_protocols TLSv1.2 TLSv1.3;
    proxy_ssl_ciphers HIGH:!aNULL:!MD5;
  '';
};
```

All ACME clients use `https://<keycloak-host>.local/acme/acme/directory` as their ACME
server URL.

---

## External Access Architecture

The intended external access path is:

```
External user → Cloud host (public IP) → WireGuard (wg-ba) → surtr (vDMZ) → backend services
```

### The Keycloak reachability problem

In a standard OAuth2 flow, the user's **browser** is redirected to Keycloak's login page.
The oauth2-proxy tells the browser "go to `https://<keycloak-host>.local/auth/realms/homelab/...`
to log in." But an external user's browser can't reach that — it's an internal hostname on
a private network.

There are two sub-flows that need Keycloak:
1. **Browser redirect** — user's browser loads Keycloak login page (needs browser → Keycloak)
2. **Token exchange** — oauth2-proxy exchanges auth code for tokens (needs surtr → Keycloak)

Flow (2) works with the firewall rule above. Flow (1) is the problem.

### Solution: proxy Keycloak through surtr

Add a `/auth` location to surtr's nginx that reverse-proxies to the Keycloak microvm.
This way, external users only ever talk to surtr (via the cloud host), and surtr handles
routing to both the backend service and Keycloak:

```
External browser                        Internal network
      │                                       │
      ├── GET /auth/realms/... ──→ surtr ──→ Keycloak microvm (vINFRA)
      ├── POST /oauth2/callback ──→ surtr (oauth2-proxy)
      └── GET / ──────────────────→ surtr ──→ backend service
```

**surtr nginx addition:**
```nix
# Block admin console — external users must not reach it (see S5)
locations."/auth/admin" = {
  return = "403";
};
locations."/auth/realms/master" = {
  return = "403";
};

# Proxy OIDC endpoints to Keycloak
locations."/auth" = {
  proxyPass = "https://<keycloak-host>.local/auth";
  extraConfig = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;  # Overwrite, don't append (see S13)
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;
  '';
};
```

**oauth2-proxy reconfiguration for external access:**

oauth2-proxy needs to use surtr-relative URLs for browser-facing redirects, while still
talking to the Keycloak microvm internally for token operations:

```nix
extraConfig = {
  "provider-display-name" = "Keycloak";
  "oidc-issuer-url" = "https://<keycloak-host>.local/auth/realms/homelab";
  "login-url" = "https://${externalDomain}/auth/realms/homelab/protocol/openid-connect/auth";
  "redeem-url" = "https://<keycloak-host>.local/auth/realms/homelab/protocol/openid-connect/token";
  "oidc-jwks-url" = "https://<keycloak-host>.local/auth/realms/homelab/protocol/openid-connect/certs";
};
redirectURL = "https://${externalDomain}/oauth2/callback";
```

This splits the URLs:
- `login-url` uses the external domain (browser-facing)
- `redeem-url` and `oidc-jwks-url` use the internal Keycloak hostname (server-side, never seen by browser)
- `oidc-issuer-url` uses the internal hostname for OIDC discovery (server-side)

**Keycloak hostname configuration:**

Keycloak needs to accept requests arriving via surtr's proxy (with a different `Host`
header than the internal hostname). Configure Keycloak with an explicit hostname for
browser-facing operations, while allowing internal backchannel access:

```nix
services.keycloak.settings = {
  # ... existing settings ...
  hostname = "<external-domain>";              # Fixed issuer URL for all tokens
  hostname-backchannel-dynamic = true;         # Internal clients (oauth2-proxy redeem,
                                               # step-ca) can use the internal hostname
};
```

This ensures tokens always have a consistent issuer (`https://<external-domain>/auth/...`)
regardless of which proxy path the request arrived through. Internal services use the
backchannel for server-to-server operations (token exchange, JWKS fetching) via the
internal hostname. See [Security Considerations S4](#security-considerations) for why
`hostname-strict = false` should be avoided.

### Cloud host configuration (future work)

The cloud host is not yet deployed. When it is, it needs:

1. **nginx/caddy** — TLS termination with a real (Let's Encrypt) certificate for the
   public domain
2. **WireGuard client** — connects to yggdrasil's wg-ba tunnel
3. **Reverse proxy rules** — forward all HTTPS traffic through WireGuard to surtr

The cloud host is intentionally minimal: it's a dumb pipe that terminates TLS and
forwards to surtr. All authentication logic lives on surtr (oauth2-proxy) and the
Keycloak microvm (vINFRA). If the cloud host is compromised, the attacker gets encrypted
WireGuard traffic and an OAuth login page — no direct access to backend services.

### Internal access (LAN users)

For users on vHOME or vINFRA, the flow is direct:
- Browser goes directly to the Keycloak microvm for OAuth login
  (trusted → management is allowed by `accessTo`)
- oauth2-proxy on surtr talks to the Keycloak microvm for token exchange
- No cloud host or external proxy involved

The oauth2-proxy `login-url` override only affects external access. For internal-only
services (e.g., alfheim's Adguard UI), the login URL points at the Keycloak microvm's
internal hostname.

---

## Static vs Dynamic Configuration

### What lives in Nix config (declarative, version-controlled)

| Component | Configuration | File |
|-----------|--------------|------|
| Keycloak service | Port, hostname, proxy-headers, database | Keycloak microvm config (vINFRA) |
| step-ca service | Address, port, provisioners, policy | step-ca microvm config (vINFRA) |
| nginx (Keycloak microvm) | Keycloak proxy, ACME proxy to step-ca | Keycloak microvm config (vINFRA) |
| nginx (surtr) | Backend proxy, /auth Keycloak proxy | `surtr/proxy.nix` |
| oauth2-proxy | Client ID, issuer URL, upstream, cookie settings | `surtr/proxy.nix` |
| ACME | Server URL, email | Per-host ACME config |
| Firewall rules | Cross-VLAN forwarding | `yggdrasil/default.nix` |
| Sops secrets refs | Secret file paths | Per-host `sops.nix` |

### What could be semi-declarative (keycloak-config-cli)

Realm structure, client registrations, groups, and authentication flows can be managed
via [keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli), a tool that
applies JSON/YAML configuration to Keycloak on startup. This bridges the gap between
"fully manual admin console" and "everything in Nix."

**How it works:** A systemd service runs after Keycloak starts, reads a JSON config file,
and creates/updates realm resources via the Keycloak admin API. It's idempotent — running
it multiple times produces the same result.

**What to manage with keycloak-config-cli:**

```json
{
  "realm": "homelab",
  "enabled": true,
  "sslRequired": "all",
  "bruteForceProtected": true,
  "accessTokenLifespan": 300,
  "ssoSessionMaxLifespan": 43200,
  "clients": [
    {
      "clientId": "oauth2-proxy",
      "protocol": "openid-connect",
      "publicClient": false,
      "directAccessGrantsEnabled": false,
      "standardFlowEnabled": true,
      "redirectUris": [
        "https://surtr.local/oauth2/callback",
        "https://EXTERNAL_DOMAIN/oauth2/callback"
      ],
      "defaultClientScopes": ["openid", "profile", "email", "groups"]
    },
    {
      "clientId": "step-ca",
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "redirectUris": ["http://127.0.0.1:*"],
      "defaultClientScopes": ["openid", "profile", "email", "groups"]
    },
    {
      "clientId": "cicd-deploy",
      "protocol": "openid-connect",
      "publicClient": false,
      "serviceAccountsEnabled": true,
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": false
    }
  ],
  "groups": [
    { "name": "admins" },
    { "name": "media-users" },
    { "name": "deploy" }
  ],
  "clientScopeMappings": {
    "oauth2-proxy": [
      { "client": "oauth2-proxy", "roles": [] }
    ]
  }
}
```

**NixOS integration sketch:**

```nix
systemd.services.keycloak-config = {
  after = [ "keycloak.service" ];
  wants = [ "keycloak.service" ];
  serviceConfig.Type = "oneshot";
  path = [ pkgs.keycloak-config-cli ];
  environment = {
    KEYCLOAK_URL = "http://127.0.0.1:9080/auth";
    KEYCLOAK_AVAILABILITYCHECK_ENABLED = "true";
    KEYCLOAK_AVAILABILITYCHECK_TIMEOUT = "120s";
    IMPORT_FILES_LOCATIONS = "/etc/keycloak/realm-config.json";
  };
  script = ''
    keycloak-config-cli
  '';
};

# The realm config file (secrets like client secrets are injected at runtime)
environment.etc."keycloak/realm-config.json".source = ./keycloak-realm.json;
```

**What stays manual (admin console only):**

- User accounts (never in config — dynamic by requirement)
- User MFA enrollment (per-user, interactive)
- User group memberships (assigned per-user via admin console)
- One-time client secret generation (generated in Keycloak, copied to sops)

### Client secret lifecycle

Client secrets are generated once in Keycloak (admin console or API), then stored in
sops for the consuming service. The lifecycle is:

1. Create client in Keycloak (via admin console or keycloak-config-cli)
2. Copy the generated client secret
3. Add to the appropriate host's sops secrets file (`sops edit secrets/secrets.yaml`)
4. Reference in Nix config (`config.sops.secrets."oauth2-proxy-client-secret".path`)
5. Rotate by regenerating in Keycloak and updating sops

This is a manual process by design — client secrets change rarely and the manual step
ensures they're properly encrypted in sops before being deployed.

---

## OIDC Integrations

### Pattern for services with native OIDC

Services that support OIDC directly (without oauth2-proxy) can authenticate against
Keycloak. The general pattern:

1. Register a client in Keycloak for the service
2. Store the client secret in sops on the service's host
3. Configure the service's OIDC settings in Nix, pointing at Keycloak's issuer URL
4. Optionally configure group-based access control via Keycloak claims

**Generic NixOS configuration pattern:**

```nix
# On the service host:
services.<service>.oidc = {
  enabled = true;
  clientId = "<service-name>";
  clientSecretFile = config.sops.secrets."<service>-oidc-secret".path;
  issuerUrl = "https://<keycloak-host>.local/auth/realms/homelab";
  scopes = [ "openid" "profile" "email" "groups" ];
};
```

### Protocol mapper: groups claim

Keycloak doesn't include group memberships in tokens by default. A **protocol mapper**
must be added to include groups in the `groups` claim of ID/access tokens. This is
configured per-client or at the realm level via a client scope:

1. Create a client scope named `groups` in the `homelab` realm
2. Add a "Group Membership" protocol mapper to it:
   - Name: `groups`
   - Mapper type: Group Membership
   - Token claim name: `groups`
   - Full group path: Off (just group names, not `/path/to/group`)
   - Add to ID token: Yes
   - Add to access token: Yes
3. Add the `groups` client scope as a default scope for all clients that need it

This can be included in the keycloak-config-cli JSON configuration.

### Services to integrate (current and planned)

| Service | Host | Integration Type | Priority |
|---------|------|-----------------|----------|
| Jellyfin | bragi (vDMZ) | oauth2-proxy (already working) | Done |
| Adguard Home | alfheim (vINFRA) | oauth2-proxy via surtr (already working) | Done |
| step-ca | dedicated microvm (vINFRA) | OIDC provisioner (SSH cert plan) | Phase 4 |
| Future services | Various | Direct OIDC or oauth2-proxy | As deployed |

For services that don't support OIDC natively, the oauth2-proxy pattern used by surtr
and alfheim scales to any number of backends. Each new backend needs:
- An nginx `location` block with `auth_request /oauth2/auth`
- The oauth2-proxy instance on surtr handles all auth (shared across backends)
- Optionally, per-location group restrictions via `--allowed-groups` or
  `X-Auth-Request-Groups` header checks

---

## User Account Management

### Account provisioning

User accounts are created dynamically via the Keycloak admin console
(`https://<keycloak-host>.local/auth/admin/`). No user information is stored in NixOS
configuration or the git repository.

**Initial admin account:** Keycloak creates a default admin account on first startup.
The password for this account is set via `services.keycloak.initialAdminPassword`
or through the Keycloak CLI. After first login, change the password and enable MFA.

**Adding users:**

1. Log into Keycloak admin console
2. Select `homelab` realm
3. Create user (username, email)
4. Set temporary password (user changes on first login)
5. Assign to groups (`admins`, `media-users`, etc.)
6. User enrolls MFA on first login (if required by group policy)

### MFA policies

- **admins group:** Required — WebAuthn (preferred) or TOTP
- **media-users group:** Optional — encouraged but not enforced for media access
- **deploy (service accounts):** N/A — uses client credentials, no interactive login

Keycloak's conditional authentication flows can enforce MFA per-group. Create a
custom authentication flow that checks group membership and conditionally requires
the OTP/WebAuthn step.

### Account lifecycle

- **Deprovisioning:** Disable or delete the user in Keycloak. All active sessions are
  immediately invalidated. oauth2-proxy cookies expire within `cookie.expire` (currently
  30min). SSH certificates expire naturally (short-lived, 12h).
- **No NixOS changes needed:** Removing a user from Keycloak requires zero configuration
  changes to any host. This is one of the key advantages of centralized auth.

---

## Resource Requirements

See the [Microvm sizing table](#microvm-sizing) in the Hosting Decision section for a
summary. Additional detail below.

### Keycloak microvm (vINFRA)

The Keycloak microvm runs Keycloak (JVM), PostgreSQL, and nginx:

| Service | Typical RAM | Notes |
|---------|------------|-------|
| Keycloak (JVM) | 512MB–768MB | Java heap + metaspace |
| PostgreSQL | 128MB–256MB | Shared buffers + connections |
| nginx | ~10MB | Reverse proxy (Keycloak + ACME passthrough) |

**2048MB** gives comfortable headroom. Constrain Keycloak's JVM heap to prevent it from
consuming all available memory:

```nix
# JVM options to cap heap usage
systemd.services.keycloak.environment = {
  JAVA_OPTS_APPEND = "-Xms256m -Xmx768m";
};
```

### step-ca microvm (vINFRA)

**512MB** is more than sufficient. step-ca is a single Go binary (~30MB resident) with a
badger database.

step-ca's persistent storage holds the CA root key material and the badger database.
This data is critical — loss means re-provisioning all certificates. Back up alongside
other infrastructure secrets.

---

## Relationship to Other Plans

### SSH Certificates Plan

The [SSH certificates plan](./ssh-certificates-sso-plan.md) depends on Keycloak being
operational and properly configured. Specifically:

- **Phase 1 (Deploy Keycloak):** This plan hardens and completes the Keycloak setup.
- **Phase 2 (Deploy step-ca with OIDC provisioner):** Requires:
  - step-ca on its own vINFRA microvm (covered in this plan's hosting decision)
  - A `step-ca` client in Keycloak (defined in this plan's client table)
  - An OIDC provisioner added to step-ca's configuration
  - Group → principal mapping (this plan's groups map to SSH principals)

The SSH cert plan should be updated to:
1. Keycloak on a dedicated vINFRA microvm (not "a vINFRA host" generically)
2. step-ca on a dedicated vINFRA microvm (not vMGMT — vMGMT becomes the locked-down
   networking gear zone after the split)
3. Reference the `homelab` realm and `step-ca` client defined here

### Zone Refactor Plan

The [zone refactor](./zone-refactor-plan.md) is a prerequisite for clean firewall rules.
After the refactor, the `extraForwardRules` for surtr → gridr can be expressed clearly.
Before the refactor, the current trust-based forwarding may implicitly allow the traffic
(the pre-refactor `trusted` interfaces set includes both vHOME and vDMZ in the internal
interfaces set). This should be explicitly verified rather than assumed.

### Secure MGMT VLAN Plan

The [vMGMT split](./secure-mgmt-vlan-plan.md) moves alfheim to vINFRA. With Keycloak
also on vINFRA:
- alfheim's OAuth auth_request to surtr still works (management → untrusted is allowed)
- alfheim reaching Keycloak is intra-zone (management → management)
- The auth infrastructure is consolidated on vINFRA alongside DNS

---

## Implementation Phases

### Phase 1: Provision Keycloak and step-ca microvms on vINFRA

**Goal:** Stand up the target infrastructure on vINFRA.

1. **Provision Keycloak microvm** on a vINFRA host with 2GB RAM, 2 vCPU
2. **Configure Keycloak** service, PostgreSQL, nginx (with /auth and /acme proxy)
3. **Add JVM heap limits** (`-Xms256m -Xmx768m`)
4. **Provision step-ca microvm** on a vINFRA host with 512MB RAM, 1 vCPU
5. **Migrate CA key material** from gridr to the new step-ca microvm
6. **Configure ACME proxy** on the Keycloak microvm's nginx → step-ca
7. **Add explicit firewall rule:** vDMZ → Keycloak microvm:443
8. **Update all ACME client configs** to point at the new Keycloak microvm's ACME URL
9. **Update surtr's oauth2-proxy config** to point at the new Keycloak microvm
   - Set `cookie.secure = true` (S1)
   - Change `redirectURL` to HTTPS (S2)
   - Remove `skip-jwt-bearer-tokens = true` (S3)
   - Disable `passAccessToken` and `set-authorization-header` unless needed (S7)
   - Replace `email.domains = ["*"]` with `--allowed-groups` once groups exist (S10)
10. **Update alfheim's proxy config** to point at the new Keycloak microvm
11. **Verify ACME, OIDC, oauth2-proxy** all work with the new locations
12. **Decommission gridr** (or repurpose) once migration is confirmed

### Phase 2: Realm restructuring

**Goal:** Replace the ad-hoc `external` realm with a properly structured `homelab` realm.

1. **Create `homelab` realm** in Keycloak admin console
2. **Register clients:** `oauth2-proxy`, `step-ca`, `cicd-deploy`
3. **Create groups:** `admins`, `media-users`, `deploy`
4. **Add `groups` protocol mapper** (client scope for group claims)
5. **Configure authentication flows:** Conditional MFA for admins
6. **Create initial user accounts**
7. **Update surtr's oauth2-proxy config** to point at `homelab` realm
8. **Update alfheim's proxy config** if realm URL changed
9. **Retire `external` realm** once all clients are migrated
10. **Evaluate keycloak-config-cli:** Optionally set up declarative realm config
    as a systemd service to make the above reproducible

### Phase 3: External access

**Goal:** Enable authenticated external access to vDMZ services via the cloud host.

1. **Add `/auth` proxy location** to surtr's nginx (proxies to Keycloak microvm)
   - Block `/auth/admin/` and `/auth/realms/master/` (S5)
   - Use `X-Forwarded-For $remote_addr` not `$proxy_add_x_forwarded_for` (S13)
2. **Configure oauth2-proxy** with split URLs (external login-url, internal redeem-url)
   - Ensure `oidc-issuer-url` matches Keycloak's `hostname` setting (S6)
3. **Configure Keycloak** `hostname = "<external-domain>"` + `hostname-backchannel-dynamic = true` (S4)
4. **Add nginx rate limiting** on surtr for `/auth/` and `/oauth2/` paths (S11)
5. **Deploy cloud host** with nginx + WireGuard + Let's Encrypt cert
   - Strip/overwrite `X-Forwarded-For` at the cloud host (S13)
6. **Add WireGuard forwarding rules** if needed for the /auth proxy path
7. **Test end-to-end:** External browser → cloud host → WireGuard → surtr → Keycloak
   login → surtr → backend service

### Phase 4: step-ca OIDC provisioner (SSH certificates)

**Goal:** Wire up step-ca's OIDC provisioner for SSH certificate issuance. step-ca is
already on vINFRA from Phase 1. Detailed in the
[SSH certificates plan](./ssh-certificates-sso-plan.md); listed here for sequencing.

1. **Add OIDC provisioner** to step-ca config, pointing at Keycloak (intra-zone)
2. **Configure group → principal mapping** (admins → admin, deploy → deploy)
3. **Test interactive SSH cert flow:** `step ssh login` → Keycloak → cert
4. **Test CI/CD cert flow:** client_credentials → token → cert

### Phase 5: Additional OIDC integrations

**Goal:** Connect additional services directly to Keycloak as they are deployed.

For each new service:
1. Register client in Keycloak (admin console or keycloak-config-cli)
2. Store client secret in sops
3. Configure service's OIDC settings in Nix
4. Test login flow
5. Configure group-based access if needed

---

## Security Considerations

> **Context:** Traffic from the internet reaches vDMZ via a WireGuard tunnel from a
> cloud host. Even though WireGuard provides encryption and the firewall limits traffic
> to HTTP(S), the services behind surtr are internet-facing and require hardening
> appropriate for that exposure.

### Architectural assessment

**What the plan gets right:**

The core trust model is sound. The architecture establishes a clear security boundary:
external traffic enters through a single chokepoint (surtr on vDMZ), must pass through
OAuth2 authentication before reaching any backend, and the identity provider (Keycloak)
lives on a more privileged zone (vINFRA) behind an explicit firewall rule. This is the
right topology — the thing that makes authorization decisions should not be on the same
trust level as the things it's protecting.

Separating step-ca and Keycloak into distinct microvms is a good call. Keycloak's
attack surface (JVM, PostgreSQL, admin console, complex web UI) is orders of magnitude
larger than step-ca's (a Go binary with a simple API). CA key material deserves
isolation from the most complex component on the network.

The zone-based firewall model with explicit `extraForwardRules` for cross-zone access
is the right pattern. The default-deny posture (untrusted cannot reach management)
means new vDMZ services don't automatically gain access to Keycloak — an explicit rule
must be added.

**Where the architecture has structural tension:**

1. **The ACME proxy co-location trades isolation for convenience.** The plan routes
   ACME traffic through the Keycloak microvm's nginx (`/acme` → step-ca). This means
   the Keycloak microvm is in the critical path for both authentication AND certificate
   issuance. A successful attack against the Keycloak microvm (e.g., via a Keycloak CVE
   or JVM exploit) gives the attacker not only the identity provider but also a proxy hop
   toward the CA. The attacker can't reach step-ca's key material directly (it's a
   separate microvm), but they can request certificates through the ACME proxy and
   potentially intercept OIDC ↔ step-ca backchannel traffic.

   This is an acceptable trade-off for a homelab — the alternative (a third vINFRA
   microvm just for ACME proxying, or a separate firewall rule from vDMZ directly to
   step-ca) adds operational complexity for marginal security gain. But it's worth
   acknowledging: the Keycloak microvm is the highest-value target on vINFRA because
   compromising it affects both auth and cert issuance.

2. **surtr is a high-value target with a large role.** surtr handles: TLS termination
   for external traffic, oauth2-proxy (authentication decisions), nginx reverse proxy
   to all backends, the `/auth` Keycloak proxy for external users, and (currently) SSH
   access from wg-ba. That's a lot of responsibility for one microvm on the least-trusted
   internal zone. If surtr is compromised, the attacker gets:
   - Access to every user's Keycloak access tokens (via `passAccessToken`, S7)
   - The ability to bypass OAuth for backend access (surtr's nginx can proxy directly)
   - A foothold on vDMZ with network access to Keycloak on vINFRA
   - SSH daemon access (via port forward, S8)

   The mitigation is that surtr is the *right* place for these responsibilities — it's
   the choke point by design. But the plan should treat surtr as a hardened bastion:
   minimal packages installed, no unnecessary services, tight firewall egress rules, and
   the fixes from S1-S7 applied. Consider whether surtr should have any outbound access
   beyond what's strictly needed (Keycloak:443, backend services, DNS).

3. **The dual-hostname pattern (internal + external) adds fragile complexity.** The
   plan requires Keycloak to serve two audiences (internal LAN users via
   `keycloak.local`, external users via `<external-domain>`) and oauth2-proxy to use
   split URLs (external login-url, internal redeem-url). This works, but every component
   in the chain must agree on which hostname to use when:
   - Keycloak's `hostname` setting determines the issuer in tokens
   - oauth2-proxy's `oidc-issuer-url` must match the token issuer
   - `login-url` must be browser-reachable
   - `redeem-url` must be server-reachable
   - Cookie domains must match the access domain
   - Redirect URIs must match what Keycloak expects

   A misconfiguration in any one of these causes authentication failures that are
   notoriously difficult to debug (OIDC error messages are often opaque). The
   `hostname` + `hostname-backchannel-dynamic` approach (S4) is the cleanest solution,
   but it still requires careful testing of both access paths (internal and external)
   after every configuration change. Consider writing a simple integration test (curl
   the OIDC discovery endpoint from both paths, verify the issuer matches).

4. **The "compromised cloud host" threat model deserves explicit treatment.** The cloud
   host is internet-facing and the least trusted component in the chain. The plan
   correctly describes it as a "dumb pipe" but doesn't fully analyze what a compromised
   cloud host can do:
   - **Can do:** See encrypted WireGuard traffic (opaque), attempt brute-force against
     the OAuth login page, attempt to exploit surtr's nginx/TLS stack through the tunnel.
   - **Can do (currently):** SSH directly to surtr via the port forward (S8).
   - **Cannot do:** Decrypt WireGuard traffic without the private key, bypass OAuth
     (assuming S3 is fixed), reach anything other than surtr (firewall restricts wg-ba
     to surtr's IP).
   - **Cannot do (but should be verified):** Reach hosts outside vDMZ via the tunnel.
     The firewall rule `{ iifname = "wg-ba"; ip.daddr = "10.0.100.40"; verdict = "accept"; }`
     restricts wg-ba traffic to surtr specifically. However, the other rule
     `{ iifname = "vDMZ.br0"; oifname = "wg-ba"; verdict = "accept"; }` allows
     vDMZ → wg-ba (for return traffic). Confirm that the nftables rules are stateful and
     that this doesn't create an unintended path.

   The cloud host threat model is overall sound: even full compromise yields only an
   OAuth login page and (with S8 fixed) no direct service access. The WireGuard tunnel +
   firewall + OAuth form a reasonable defense-in-depth stack for a homelab.

5. **Single point of failure: Keycloak availability.** If the Keycloak microvm goes
   down, oauth2-proxy cannot validate sessions (refresh fails after `cookie.refresh`
   interval), new logins are impossible, and step-ca's OIDC provisioner stops working.
   ACME renewals also fail (since they're proxied through the same microvm). This isn't a
   security concern per se, but availability is part of the security posture — if
   Keycloak goes down and an operator bypasses OAuth to restore access, that bypass could
   leave a hole.

   For a homelab, this is acceptable. Don't build HA Keycloak. But do ensure that
   recovery is well-documented and doesn't require disabling security controls. Keycloak
   data (PostgreSQL) should be backed up regularly; recovery means restoring the microvm
   from backup or re-provisioning from Nix config + database backup.

**Overall verdict:** The architecture is sound for a homelab. The trust boundaries are
in the right places, the firewall model is restrictive by default, and the
identity provider is appropriately isolated from the DMZ. The main risks are
implementation-level (the S1-S13 findings below) rather than architectural. The two
structural points worth tracking are: surtr's outsized role as the internet-facing
bastion, and the ACME proxy co-location on the Keycloak microvm. Neither requires
architectural changes, but both warrant extra care during implementation.

### Specific findings: Critical — Must fix before external access

**S1. `cookie.secure = false` in oauth2-proxy (surtr/proxy.nix:69)**

The OAuth session cookie is sent over HTTP. Any network observer between the user and
surtr can steal the cookie and hijack the session. This is currently mitigated by the
fact that all traffic is on the LAN or inside a WireGuard tunnel, but:
- The plan enables external access, where the cloud host terminates TLS and forwards
  to surtr. If the cloud-to-surtr path ever drops to HTTP (misconfiguration, debugging),
  cookies leak.
- Defense in depth: `cookie.secure = true` costs nothing and prevents an entire class
  of mistakes.

**Fix:** Set `cookie.secure = true`. Ensure all paths to surtr use HTTPS (the cloud
host should forward HTTPS-terminated traffic to surtr's HTTPS port, or surtr should
enforce TLS on all cookie-bearing endpoints).

**S2. `redirectURL = "http://surtr.local/oauth2/callback"` (surtr/proxy.nix:63)**

The OAuth2 redirect URI uses `http://`. After the authorization code grant, Keycloak
redirects the user's browser to this URL with the authorization code in the query
string. Over HTTP, the authorization code is visible to any network observer. An
attacker who captures it can exchange it for tokens (the auth code is single-use but
the race window exists).

**Fix:** Change to `https://surtr.local/oauth2/callback` for internal access and
`https://<external-domain>/oauth2/callback` for external access (as already shown in
the plan's oauth2-proxy reconfiguration section).

**S3. `skip-jwt-bearer-tokens = true` (surtr/proxy.nix:78)**

This tells oauth2-proxy to accept any request that includes a valid JWT bearer token
in the `Authorization` header, **bypassing the entire OAuth login flow**. Any service
or user that possesses a valid Keycloak access token (from any client, any flow) can
access all oauth2-proxy-protected services by including it as a bearer token.

The threat: if any Keycloak client is compromised, or if any service that receives
access tokens (via `passAccessToken`) is compromised, the leaked token grants access
to every oauth2-proxy-gated service.

**Fix:** Remove `skip-jwt-bearer-tokens = true` unless there is a specific
machine-to-machine use case that requires it. If needed, use `--skip-jwt-bearer-tokens`
with `--extra-jwt-issuers` to restrict which issuers/audiences are accepted, rather
than accepting all valid JWTs.

**S4. `hostname-strict = false` for Keycloak (plan, Phase 3)**

The plan recommends `hostname-strict = false` so Keycloak accepts requests with
different `Host` headers (internal hostname vs. external domain). This tells Keycloak
to derive its issuer URL from the incoming request's `Host` header. Risks:
- **Token issuer confusion:** If an attacker can influence the `Host` header (e.g., via
  a misconfigured upstream proxy or a direct request with a crafted Host), Keycloak
  issues tokens with an attacker-controlled issuer URL. Downstream services that
  validate the issuer may accept or reject tokens unpredictably.
- **Open redirect:** Keycloak uses the derived hostname for redirect URIs. A crafted
  `Host` header could redirect users to an attacker-controlled domain after login.

**Fix:** Use explicit hostname configuration instead:
```nix
services.keycloak.settings = {
  hostname = "<external-domain>";                  # Browser-facing URL
  hostname-backchannel-dynamic = true;             # Internal clients use request Host
  # hostname-strict = true;  (default, leave it)
};
```
This way Keycloak uses a fixed hostname for browser-facing operations (login pages,
token issuer) but allows internal clients (oauth2-proxy's redeem-url, step-ca) to
reach it via the internal hostname for backchannel operations. This eliminates the
Host header manipulation risk while still supporting dual-hostname access.

**S5. Keycloak admin console exposed to external users (plan, Phase 3)**

The plan adds a `/auth` proxy location on surtr that forwards all `/auth/*` requests
to the Keycloak microvm. This includes `/auth/admin/` — the Keycloak admin console.
External users can reach the admin login page and attempt credential attacks.

**Fix:** Block the admin console path in surtr's nginx:
```nginx
location /auth/admin/ {
    return 403;
}
location /auth/realms/homelab/protocol/ {
    # Allow: OIDC endpoints needed by oauth2-proxy and user browsers
    proxy_pass https://<keycloak-host>.local/auth/realms/homelab/protocol/;
    ...
}
```
Whitelist only the paths external users need:
- `/auth/realms/homelab/protocol/openid-connect/*` (login, token, certs, userinfo)
- `/auth/realms/homelab/login-actions/*` (login forms, consent)
- `/auth/resources/*` (Keycloak static assets: CSS, JS, images for login theme)

Block everything else (`/auth/admin/*`, `/auth/realms/master/*`, other realms).

**S6. OIDC issuer mismatch between proxy paths (plan, Phase 3)**

The plan's surtr `/auth` proxy forwards `Host $host` (the external domain) to
Keycloak. If Keycloak's hostname is configured correctly per S4 above, the issuer in
tokens will be `https://<external-domain>/auth/realms/homelab`. But oauth2-proxy's
`oidc-issuer-url` is set to `https://<keycloak-host>.local/auth/realms/homelab`.

Token validation will fail: oauth2-proxy fetches the OIDC discovery document from the
internal URL (issuer = internal hostname), but the ID token's `iss` claim contains
the external hostname.

**Fix:** With the `hostname` / `hostname-backchannel-dynamic` approach from S4:
- Set `oidc-issuer-url` in oauth2-proxy to `https://<external-domain>/auth/realms/homelab`
  (matches what Keycloak puts in tokens for browser-initiated flows)
- Set `redeem-url` and `oidc-jwks-url` to the internal hostname (backchannel, which
  Keycloak serves with `hostname-backchannel-dynamic = true`)
- Alternatively, configure oauth2-proxy to skip issuer verification
  (`--insecure-oidc-skip-issuer-verification`), but this weakens security

The cleanest approach is to ensure the issuer is consistent: Keycloak always stamps
tokens with the external domain, and oauth2-proxy's `oidc-issuer-url` matches.

### Specific findings: High — Should fix

**S7. `passAccessToken = true` + `set-authorization-header = true` (surtr/proxy.nix:71,77)**

oauth2-proxy passes the Keycloak access token to every backend service in the
`Authorization` header and `X-Forwarded-Access-Token` header. If any backend service
is compromised, the attacker obtains valid Keycloak access tokens for every user who
accesses that service. These tokens can be used to:
- Access other Keycloak-protected services (if `skip-jwt-bearer-tokens` is enabled)
- Query Keycloak's userinfo endpoint to enumerate user data
- Act as the user against any service that trusts Keycloak tokens

**Fix:** Disable unless a specific backend needs it:
```nix
passAccessToken = false;
extraConfig = {
  "set-authorization-header" = false;
};
```
If a specific backend needs the token (e.g., for user identity), pass it selectively
via per-location nginx configuration rather than globally.

**S8. SSH port forward from wg-ba to surtr:22 (yggdrasil/default.nix:76-82)**

The current firewall config forwards port 22 from the wg-ba WireGuard tunnel directly
to surtr's SSH daemon. wg-ba connects to the cloud host, which is internet-facing.
If the cloud host is compromised, the attacker gets direct SSH access to surtr (gated
only by SSH authentication, not by OAuth).

This is outside the scope of this plan but is part of the same attack surface: the
cloud host is the entry point for both web traffic (via HTTP) and SSH (via port
forward).

**Recommendation:** Remove the SSH port forward. Use WireGuard VPN (wg-vpn) for
administrative SSH access instead — wg-vpn is trusted and intended for direct device
access. If SSH from the cloud host is operationally required, restrict it with
`AllowUsers` or a bastion pattern, and require key-only auth (no passwords).

**S9. ACME provisioner has no authorization (gridr/modules/auth.nix:99-103)**

step-ca's ACME provisioner has no access control beyond network reachability and the
certificate policy (`*.local`, `10.0.0.0/16`, etc.). After the migration, any vDMZ
host that can reach the Keycloak microvm's `/acme` proxy can request certificates for
**any** `*.local` hostname — including `keycloak.local`, `alfheim.local`, or
`yggdrasil.local`.

A compromised vDMZ service (e.g., a vulnerable web app on bragi) could:
1. Request a TLS certificate for `keycloak.local`
2. Use it to MITM internal traffic (limited impact since vDMZ can't route to vINFRA
   arbitrarily, but still a certificate integrity concern)

**Fix options:**
- **ACME account binding:** Require ACME accounts to be pre-registered (step-ca
  supports external account binding)
- **Narrower certificate policy per zone:** If possible, restrict the ACME
  provisioner so vDMZ-sourced requests can only get certs for `*.local` names that
  correspond to actual vDMZ services (e.g., `surtr.local`, `bragi.local`). This may
  require multiple ACME provisioners or a webhook authorizer.
- **IP-based policy in step-ca:** step-ca supports policy per provisioner; tie
  allowed DNS names to the source network. (step-ca may not support source-IP-based
  policy natively — investigate.)
- **Minimum viable:** Accept the risk for now, since the firewall rule already
  constrains which hosts can reach the ACME endpoint, and the cert policy is limited
  to `*.local`. Document as a known risk.

### Specific findings: Medium — Defense in depth

**S10. `email.domains = ["*"]` (surtr/proxy.nix:64)**

oauth2-proxy allows any email domain. Since Keycloak is the only identity source and
user creation is manual, this is low risk in practice — but it removes a
defense-in-depth layer.

**Fix:** Set to a specific domain once user accounts use a consistent email domain.
Alternatively, use `--allowed-groups` to restrict access by Keycloak group membership
(more granular than email domain filtering).

**S11. No rate limiting on externally-reachable endpoints**

The oauth2-proxy login flow, Keycloak login page, and ACME endpoint are all reachable
from the internet (via wg-ba → surtr). There is no network-level rate limiting.
Keycloak has built-in brute force protection (enabled in the plan's realm config), but:
- oauth2-proxy itself has no rate limiting
- nginx on surtr has no `limit_req` zones configured
- A flood of requests could exhaust resources on surtr or the Keycloak microvm

**Fix:** Add nginx rate limiting on surtr for auth-related paths:
```nginx
limit_req_zone $binary_remote_addr zone=auth:10m rate=10r/s;

location /oauth2/ {
    limit_req zone=auth burst=20;
    ...
}
location /auth/ {
    limit_req zone=auth burst=20;
    ...
}
```

**S12. vDMZ → Keycloak firewall rule is zone-wide (plan)**

The plan's firewall rule allows `iifname = "vDMZ.br0"` → Keycloak microvm. This
means any current or future vDMZ host can reach Keycloak. While all vDMZ hosts with
ACME need this, a compromised host could also hit Keycloak's OIDC endpoints.

**Fix (optional):** Restrict source IPs to known vDMZ hosts:
```nix
{
  iifname = "vDMZ.br0";
  oifname = "vINFRA.br0";
  ip.saddr = { "10.0.100.40" "10.0.100.50" "10.0.100.51" };  # surtr, bragi, njord
  ip.daddr = "<keycloak-microvm-ip>";
  tcp.dport = 443;
  verdict = "accept";
}
```
This adds maintenance overhead (must update when adding vDMZ hosts) but limits blast
radius. Whether this is worth it depends on how many vDMZ hosts there will be.

**S13. X-Forwarded-For trust chain across multiple proxies**

The external access path has three proxy hops: cloud host nginx → surtr nginx →
Keycloak microvm nginx. Each adds `X-Forwarded-For`. Keycloak needs to know how
many hops to trust (`proxy-headers = "forwarded|xforwarded"` is configured but
without a trusted proxy count). If Keycloak trusts all `X-Forwarded-For` entries,
an attacker can spoof their source IP by including a fake `X-Forwarded-For` header
in the original request.

**Fix:** Configure the cloud host nginx to strip/overwrite `X-Forwarded-For` (set
it rather than append). On surtr and the Keycloak microvm, use
`proxy_set_header X-Forwarded-For $remote_addr` (not `$proxy_add_x_forwarded_for`)
to prevent spoofing from earlier hops, or configure trusted proxy addresses.

### Specific findings: Low / Informational

**S14. Cookie domain scoping**

The commented-out `cookie.domain` in surtr's config means cookies are scoped to the
request's domain. For external access, this could mean cookies scoped to the external
domain don't apply to `surtr.local`, and vice versa. This is more of a functionality
issue than security, but misconfigured cookie domains can lead to cookies leaking to
unintended subdomains.

**Recommendation:** Explicitly set `cookie.domain` to match the access pattern
(external domain for external access, `.local` for internal).

**S15. Revocation latency**

When a user is disabled in Keycloak, existing oauth2-proxy cookies remain valid until
the next refresh. With `cookie.refresh = "1m"`, the effective revocation window is
~1 minute (the refresh call to Keycloak will fail, invalidating the session). For SSH
certificates, the window is the certificate lifetime (12h in the SSH cert plan). This
is acceptable for a homelab but should be documented.

**S16. alfheim's auth_request passes Host as `$host` (alfheim/modules/proxy.nix:32,45)**

alfheim's nginx sends `Host: alfheim.local` to surtr's oauth2-proxy for auth_request
calls. oauth2-proxy may use this Host header for redirect construction, potentially
sending users to `alfheim.local/oauth2/...` instead of `surtr.local/oauth2/...`. This
is a functionality concern more than security, but could cause confused redirect loops
if not tested carefully.

### Summary of required changes to the plan

| ID | Finding | Plan section to update |
|----|---------|----------------------|
| S1 | `cookie.secure = true` | Phase 1 (surtr proxy config) |
| S2 | HTTPS redirect URL | Phase 1 (surtr proxy config) |
| S3 | Remove `skip-jwt-bearer-tokens` | Phase 1 (surtr proxy config) |
| S4 | Use `hostname` + `hostname-backchannel-dynamic` instead of `hostname-strict = false` | Phase 3 (External access, Keycloak hostname) |
| S5 | Block admin console in surtr proxy | Phase 3 (External access, surtr /auth proxy) |
| S6 | Align OIDC issuer URL with Keycloak hostname | Phase 3 (External access, oauth2-proxy URLs) |
| S7 | Disable `passAccessToken` / `set-authorization-header` | Phase 1 (surtr proxy config) |
| S8 | Remove SSH port forward from wg-ba | Separate task (not strictly this plan) |
| S9 | Investigate ACME provisioner authorization | Phase 1 (step-ca config) |
| S10 | Replace `email.domains = ["*"]` with group-based access | Phase 2 (realm restructuring) |
| S11 | Add nginx rate limiting | Phase 3 (surtr nginx config) |
| S12 | Consider narrowing firewall source IPs | Phase 1 (firewall rules) |
| S13 | Fix X-Forwarded-For trust chain | Phase 3 (proxy chain config) |

---

## Complete File Change List

| File | Phase | Changes |
|------|-------|---------|
| Keycloak microvm config (new, on vINFRA host) | 1 | New microvm: Keycloak, PostgreSQL, nginx (/auth + /acme proxy), sops secrets |
| step-ca microvm config (new, on vINFRA host) | 1 | New microvm: step-ca service, CA key material, sops secrets |
| `hosts/yggdrasil/default.nix` | 1 | Add vDMZ → Keycloak microvm firewall rule, add DNS entries |
| `hosts/muspelheim/guests/surtr/proxy.nix` | 1, 2, 3 | Update OIDC issuer URL, update realm, add `/auth` proxy location, split oauth2-proxy URLs |
| `hosts/yggdrasil/guests/alfheim/modules/proxy.nix` | 1 | Update OAuth proxy URLs to Keycloak microvm |
| Per-host ACME configs | 1 | Update ACME server URL from gridr.local to Keycloak microvm |
| `hosts/muspelheim/guests/surtr/sops.nix` | 2 | Update oauth2-proxy key file for new realm |
| gridr config (retire/repurpose) | 1 | Remove Keycloak, step-ca, and associated nginx/sops config |
| `llm-notes/ssh-certificates-sso-plan.md` | — | Update Keycloak and step-ca placement (both vINFRA) |
