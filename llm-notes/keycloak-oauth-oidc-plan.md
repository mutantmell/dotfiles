# Keycloak OAuth2 / OIDC Integration Plan

> **Status:** Planning. Keycloak and step-ca are already deployed on gridr. oauth2-proxy
> is deployed on surtr. This plan covers completing and hardening the integration.

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

## Current State

### Already deployed

| Component | Location | Network | Config file |
|-----------|----------|---------|-------------|
| Keycloak | gridr | vHOME (10.0.20.30) | `hosts/jotunheimr/guests/gridr/modules/auth.nix` |
| step-ca | gridr | vHOME (10.0.20.30) | same file |
| oauth2-proxy | surtr | vDMZ (10.0.100.40) | `hosts/muspelheim/guests/surtr/proxy.nix` |
| nginx (auth proxy) | gridr | vHOME | `hosts/jotunheimr/guests/gridr/modules/auth.nix` |
| nginx (OAuth-gated Adguard) | alfheim | vMGMT (10.0.10.2) | `hosts/yggdrasil/guests/alfheim/modules/proxy.nix` |

### What exists in Keycloak today

- An `external` realm with an `oauth2-proxy` client (referenced by surtr's config)
- Keycloak accessible at `https://gridr.local/auth`
- OIDC issuer URL: `https://gridr.local/auth/realms/external`

### What's missing

- No OIDC provisioner on step-ca (SSH cert flow not wired up)
- No declarative realm/client configuration (realm was set up manually)
- No group/role structure for access control
- No cross-VLAN firewall rules for vDMZ → gridr (currently relying on the pre-zone-refactor
  trust model where `trusted` and `untrusted` forwarding is more permissive than intended)
- External access architecture not designed (cloud host → WireGuard → oauth2-proxy → Keycloak)
- gridr resource constraints (1GB RAM is tight for Keycloak + PostgreSQL + step-ca + nginx)

---

## Hosting Decision

### Where Keycloak lives: gridr on vHOME

Keep Keycloak on gridr (vHOME, 10.0.20.30). The SSH certificates plan mentions vINFRA as a
possible location, but gridr on vHOME is the better fit for the full set of use cases:

| Consideration | vHOME (gridr) | vINFRA |
|---------------|---------------|--------|
| Already deployed and working | Yes | Would require migration |
| Can reach vDMZ services | Yes (trusted → untrusted) | Yes (management → untrusted) |
| Can be reached from vDMZ | No (needs explicit rule) | No (needs explicit rule) |
| User-facing auth service | Natural fit (user device zone) | Infrastructure zone feels wrong for user-facing login |
| Co-located with step-ca | Yes (simplifies auth pipeline) | Would split auth components across zones |
| Internet access for CRL/updates | Yes (trusted → external) | Yes (management → external, filtered) |

The firewall situation is identical in both cases: the `untrusted` zone (vDMZ) cannot initiate
connections to either `trusted` or `management` zones. Regardless of where Keycloak lives,
surtr needs an explicit firewall rule to reach it for OIDC token exchange.

### step-ca: stay on gridr for now

The SSH certificates plan envisions step-ca on a dedicated vMGMT microvm for key material
isolation. That's a sound long-term goal, but for now step-ca and Keycloak are tightly coupled
(the OIDC provisioner needs to reach Keycloak), and co-locating them avoids cross-network
dependencies during the auth flow. When the SSH certificate work becomes active, splitting
step-ca out can be revisited.

### Update to SSH certificates plan

The SSH certificates plan should be updated to reflect that Keycloak stays on gridr (vHOME)
rather than moving to vINFRA. The architecture diagram changes from:

```
Keycloak (vINFRA) ← OIDC → step-ca (vMGMT microvm)
```

to:

```
Keycloak + step-ca (gridr, vHOME) — may split step-ca to vMGMT microvm later
```

The rest of the SSH certificate plan (TrustedUserCAKeys, principals, host certs) is unaffected.

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
- `step-ca` OIDC provisioner secret → gridr's sops secrets
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

| Source | Destination | Port | Purpose |
|--------|-------------|------|---------|
| surtr (vDMZ) | gridr (vHOME) | 443 | oauth2-proxy → Keycloak OIDC token exchange |
| surtr (vDMZ) | gridr (vHOME) | 443 | oauth2-proxy → Keycloak OIDC discovery |
| alfheim (vMGMT/vINFRA) | surtr (vDMZ) | 443 | alfheim nginx → surtr oauth2-proxy (auth_request) |
| alfheim (vMGMT/vINFRA) | gridr (vHOME) | 443 | (already allowed — management/trusted → trusted) |
| wg-ba peers | surtr (vDMZ) | 443 | External web traffic (already in extraForwardRules) |

The first two rows are the critical addition. surtr must reach gridr for the server-side
OIDC token exchange (authorization code → access token). This is a backend call, not a
browser redirect.

**Implementation** — add to `extraForwardRules` on yggdrasil:

```nix
firewall.extraForwardRules = [
  # Existing rules
  { iifname = "vDMZ.br0"; oifname = "wg-ba"; verdict = "accept"; }
  { iifname = "wg-ba"; ip.daddr = "10.0.100.40"; verdict = "accept"; }

  # New: oauth2-proxy on surtr needs to reach Keycloak on gridr for OIDC
  {
    iifname = "vDMZ.br0";
    oifname = "vHOME.br0";
    ip.saddr = "10.0.100.40";
    ip.daddr = "10.0.20.30";
    tcp.dport = 443;
    verdict = "accept";
    comment = "surtr oauth2-proxy -> gridr Keycloak OIDC";
  }
];
```

This is deliberately narrow: only surtr's IP, only to gridr's IP, only port 443. No
blanket vDMZ → vHOME forwarding.

**Note on alfheim → surtr:** alfheim currently proxies OAuth requests to surtr
(`https://surtr.local/oauth2/`). After the vMGMT/vINFRA split, alfheim moves to vINFRA
(management zone). Since `management` → `untrusted` is in `accessTo`, this path is
already allowed — no extra rule needed.

---

## External Access Architecture

The intended external access path is:

```
External user → Cloud host (public IP) → WireGuard (wg-ba) → surtr (vDMZ) → backend services
```

### The Keycloak reachability problem

In a standard OAuth2 flow, the user's **browser** is redirected to Keycloak's login page.
The oauth2-proxy tells the browser "go to `https://gridr.local/auth/realms/homelab/...`
to log in." But an external user's browser can't reach `gridr.local` — it's an internal
hostname on a private network.

There are two sub-flows that need Keycloak:
1. **Browser redirect** — user's browser loads Keycloak login page (needs browser → Keycloak)
2. **Token exchange** — oauth2-proxy exchanges auth code for tokens (needs surtr → Keycloak)

Flow (2) works with the firewall rule above. Flow (1) is the problem.

### Solution: proxy Keycloak through surtr

Add a `/auth` location to surtr's nginx that reverse-proxies to gridr's Keycloak. This
way, external users only ever talk to surtr (via the cloud host), and surtr handles
routing to both the backend service and Keycloak:

```
External browser                        Internal network
      │                                       │
      ├── GET /auth/realms/... ──→ surtr ──→ gridr (Keycloak)
      ├── POST /oauth2/callback ──→ surtr (oauth2-proxy)
      └── GET / ──────────────────→ surtr ──→ backend service
```

**surtr nginx addition:**
```nix
locations."/auth" = {
  proxyPass = "https://gridr.local/auth";
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
talking to gridr internally for token operations:

```nix
extraConfig = {
  "provider-display-name" = "Keycloak";
  "oidc-issuer-url" = "https://gridr.local/auth/realms/homelab";
  "login-url" = "https://${externalDomain}/auth/realms/homelab/protocol/openid-connect/auth";
  "redeem-url" = "https://gridr.local/auth/realms/homelab/protocol/openid-connect/token";
  "oidc-jwks-url" = "https://gridr.local/auth/realms/homelab/protocol/openid-connect/certs";
};
redirectURL = "https://${externalDomain}/oauth2/callback";
```

This splits the URLs:
- `login-url` uses the external domain (browser-facing)
- `redeem-url` and `oidc-jwks-url` use gridr.local (server-side, never seen by browser)
- `oidc-issuer-url` stays as gridr.local for OIDC discovery (server-side)

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
forwards to surtr. All authentication logic lives on surtr (oauth2-proxy) and gridr
(Keycloak). If the cloud host is compromised, the attacker gets encrypted WireGuard
traffic and an OAuth login page — no direct access to backend services.

### Internal access (LAN users)

For users on vHOME or vMGMT/vINFRA, the existing flow works unchanged:
- Browser goes directly to `gridr.local` for OAuth login
- oauth2-proxy on surtr talks to `gridr.local` for token exchange
- No cloud host or external proxy involved

The oauth2-proxy `login-url` override only affects external access. For internal-only
services (e.g., alfheim's Adguard UI), the login URL can stay as `gridr.local`.

---

## Static vs Dynamic Configuration

### What lives in Nix config (declarative, version-controlled)

| Component | Configuration | File |
|-----------|--------------|------|
| Keycloak service | Port, hostname, proxy-headers, database | `gridr/modules/auth.nix` |
| step-ca service | Address, port, provisioners, policy | `gridr/modules/auth.nix` |
| nginx reverse proxy | Virtual hosts, locations, TLS | `gridr/modules/auth.nix`, `surtr/proxy.nix` |
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
  issuerUrl = "https://gridr.local/auth/realms/homelab";
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
| Adguard Home | alfheim (vMGMT/vINFRA) | oauth2-proxy via surtr (already working) | Done |
| step-ca | gridr (vHOME) | OIDC provisioner (SSH cert plan) | Phase 2 |
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
(`https://gridr.local/auth/admin/`). No user information is stored in NixOS
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

### gridr needs more RAM

gridr currently has 1GB RAM (`microvm.mem = 1024` in `gridr/microvm.nix`). It runs:

| Service | Typical RAM | Notes |
|---------|------------|-------|
| Keycloak (JVM) | 512MB–768MB | Java heap + metaspace |
| PostgreSQL | 128MB–256MB | Shared buffers + connections |
| step-ca | ~30MB | Go binary, minimal |
| nginx | ~10MB | Reverse proxy, minimal |

**1GB is insufficient.** Keycloak alone can consume 512MB+ under normal operation, and
JVM garbage collection pressure with only ~200MB headroom causes latency spikes and
potential OOM kills.

**Recommendation:** Increase gridr's RAM to 2048MB:

```nix
# hosts/jotunheimr/guests/gridr/microvm.nix
microvm.mem = 2048;  # Changed from 1024
```

Additionally, constrain Keycloak's JVM heap to prevent it from consuming all available
memory:

```nix
services.keycloak.settings = {
  # ... existing settings ...
};
# JVM options to cap heap usage
systemd.services.keycloak.environment = {
  JAVA_OPTS_APPEND = "-Xms256m -Xmx768m";
};
```

### gridr persistent storage

gridr's persist volume is currently 100MB × 1024 = 100GB (the `size` field in microvm
volumes is in MiB). This is more than sufficient for Keycloak's PostgreSQL database and
step-ca's badger database.

---

## Relationship to Other Plans

### SSH Certificates Plan

The [SSH certificates plan](./ssh-certificates-sso-plan.md) depends on Keycloak being
operational and properly configured. Specifically:

- **Phase 1 (Deploy Keycloak):** Already done. This plan hardens and completes the setup.
- **Phase 2 (Deploy step-ca with OIDC provisioner):** Requires:
  - A `step-ca` client in Keycloak (defined in this plan's client table)
  - An OIDC provisioner added to step-ca's configuration
  - Group → principal mapping (this plan's groups map to SSH principals)

The SSH cert plan should be updated to:
1. Reference gridr (vHOME) instead of "a vINFRA host" for Keycloak's location
2. Note that step-ca stays co-located with Keycloak for now (may split later)
3. Reference the `homelab` realm and `step-ca` client defined here

### Zone Refactor Plan

The [zone refactor](./zone-refactor-plan.md) is a prerequisite for clean firewall rules.
After the refactor, the `extraForwardRules` for surtr → gridr can be expressed clearly.
Before the refactor, the current trust-based forwarding may implicitly allow the traffic
(the pre-refactor `trusted` interfaces set includes both vHOME and vDMZ in the internal
interfaces set). This should be explicitly verified rather than assumed.

### Secure MGMT VLAN Plan

The [vMGMT split](./secure-mgmt-vlan-plan.md) moves alfheim to vINFRA. After this move:
- alfheim's OAuth auth_request to surtr still works (management → untrusted is allowed)
- alfheim reaching gridr still works (management → trusted is allowed)
- No changes to the Keycloak/OAuth architecture needed

---

## Implementation Phases

### Phase 1: Harden existing deployment

**Goal:** Fix the resource constraints and firewall gaps in the current setup.

1. **Increase gridr RAM** to 2048MB (`gridr/microvm.nix`)
2. **Add JVM heap limits** for Keycloak (`-Xms256m -Xmx768m`)
3. **Add explicit firewall rule:** surtr → gridr:443 (`yggdrasil/default.nix`)
4. **Verify cross-VLAN connectivity:** surtr can reach gridr's OIDC endpoints
5. **Verify oauth2-proxy still works** after firewall rule changes

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

1. **Add `/auth` proxy location** to surtr's nginx (proxies to gridr's Keycloak)
2. **Configure oauth2-proxy** with split URLs (external login-url, internal redeem-url)
3. **Configure Keycloak** `hostname-strict = false` (accept multiple Host headers)
4. **Deploy cloud host** with nginx + WireGuard + Let's Encrypt cert
5. **Add WireGuard forwarding rules** if needed for the /auth proxy path
6. **Test end-to-end:** External browser → cloud host → WireGuard → surtr → Keycloak
   login → surtr → backend service

### Phase 4: step-ca OIDC provisioner (SSH certificates)

**Goal:** Wire up step-ca to issue SSH certificates via Keycloak authentication.
Detailed in the [SSH certificates plan](./ssh-certificates-sso-plan.md); listed here
for sequencing.

1. **Add OIDC provisioner** to step-ca config on gridr
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
| `hosts/jotunheimr/guests/gridr/microvm.nix` | 1 | `microvm.mem = 2048` |
| `hosts/jotunheimr/guests/gridr/modules/auth.nix` | 1, 3 | JVM heap limits, `hostname-strict = false` |
| `hosts/yggdrasil/default.nix` | 1 | Add surtr → gridr firewall rule |
| `hosts/muspelheim/guests/surtr/proxy.nix` | 2, 3 | Update realm URL, add `/auth` proxy location, split oauth2-proxy URLs |
| `hosts/yggdrasil/guests/alfheim/modules/proxy.nix` | 2 | Update realm URL if changed |
| `hosts/jotunheimr/guests/gridr/sops.nix` | 4 | Add step-ca OIDC client secret |
| `hosts/jotunheimr/guests/gridr/secrets/secrets.yaml` | 2, 4 | New secrets for client credentials |
| `hosts/muspelheim/guests/surtr/sops.nix` | 2 | Update oauth2-proxy key file if realm changes |
| `llm-notes/ssh-certificates-sso-plan.md` | — | Update Keycloak location reference |
