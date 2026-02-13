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
locations."/auth" = {
  proxyPass = "https://<keycloak-host>.local/auth";
  extraConfig = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
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
header than `gridr.local`). Configure Keycloak to trust forwarded headers:

```nix
services.keycloak.settings = {
  # ... existing settings ...
  hostname-strict = false;  # Accept requests with any Host header
  # OR for more control:
  # hostname = "<external-domain>";
  # hostname-backchannel-dynamic = true;  # Allow internal clients to use gridr.local
};
```

`hostname-strict = false` is the simplest approach for a homelab with both internal and
external access patterns. It tells Keycloak to derive its own URL from the incoming
request's `Host` header rather than enforcing a fixed hostname.

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
2. **Configure oauth2-proxy** with split URLs (external login-url, internal redeem-url)
3. **Configure Keycloak** `hostname-strict = false` (accept multiple Host headers)
4. **Deploy cloud host** with nginx + WireGuard + Let's Encrypt cert
5. **Add WireGuard forwarding rules** if needed for the /auth proxy path
6. **Test end-to-end:** External browser → cloud host → WireGuard → surtr → Keycloak
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
