# Authelia Migration Plan: Replace Keycloak with Authelia

Plan date: 2026-04-19

## Motivation

Keycloak is significantly over-provisioned for this homelab's actual auth needs.
The deployment uses a fraction of Keycloak's capabilities: OIDC token issuance,
group claims, and JWKS-based token validation. Features that justified Keycloak
in the original plan — dynamic user management, client credentials grant for
CI/CD, fine-grained authorization, multi-realm support — turned out to be
unused or superseded by other design choices.

Authelia is a lightweight Go-based authentication server with OIDC provider
capabilities. It replaces both Keycloak (identity provider) and oauth2-proxy
(auth gateway) in a single ~50MB binary, compared to Keycloak's JVM +
PostgreSQL stack requiring 2GB RAM and 100GB persistent storage.

### Resource savings

| Resource        | Keycloak (messeldam) | Authelia         |
| --------------- | -------------------- | ---------------- |
| RAM             | 2048 MB              | 256–512 MB       |
| vCPU            | 2                    | 1                |
| Persistent disk | 100 GB (PostgreSQL)  | < 1 GB (SQLite)  |
| Dependencies    | JVM, PostgreSQL      | None (Go binary) |

### Complexity shed

Beyond resource savings, Authelia eliminates several pieces of infrastructure
that exist only to work around Keycloak's weight:

- **oauth2-proxy sidecar on langport and phantasma.** Each host that needs
  auth gating currently runs its own oauth2-proxy instance with its own sops
  secrets, OIDC client registration, and systemd retry config. Authelia is
  both the identity provider and the `auth_request` handler — nginx on
  langport/phantasma sends `auth_request` directly to the central Authelia
  instance. The per-host sidecar, its keyfile secret, and its client
  registration all go away.

- **Boot-time circular dependency hacks.** Keycloak's JVM takes long enough
  to start that step-ca's OIDC provisioner fails on first boot, requiring
  the `step-ca-oidc-retry` service on basel (checks Keycloak reachability,
  then restarts step-ca). Similarly, oauth2-proxy on langport and phantasma
  both have `RestartSec`/`StartLimitBurst` retry configs because they fail
  OIDC discovery during Keycloak's boot window. Authelia starts in under a
  second — all of these retry hacks become unnecessary.

- **JVM heap tuning.** The `JAVA_OPTS_APPEND = "-Xms256m -Xmx768m"` cap on
  messeldam's Keycloak service exists to prevent the JVM from consuming all
  available RAM. Not applicable to a Go binary.

- **PostgreSQL persistence and backups.** Keycloak requires PostgreSQL,
  which needs a 100GB persist volume, backup consideration, and adds to the
  mutable state surface. Authelia uses SQLite for session/OIDC state (tiny,
  low-value, reconstructable).

- **Admin console hardening.** Keycloak exposes a powerful admin console at
  `/admin` and `/realms/master` that can create users, modify clients, change
  auth policies, and extract secrets at runtime. Significant effort was spent
  restricting access: langport blocks `/admin` and `/realms/master` from
  external users (security recommendation R1), hostname-based admin
  restriction was configured, and the ordis compromise analysis identified
  the admin console as a high-value target. Authelia eliminates this entire
  attack surface — there is no admin console, no admin API, no runtime
  mutation path. All configuration is static YAML managed through Nix. An
  attacker who compromises the auth server cannot escalate to creating users
  or modifying OIDC clients without access to the Nix deployment pipeline.
  Security recommendations R1 and R4 from the roadmap analysis become
  structurally impossible rather than requiring active defense.

### Capabilities unlocked

Authelia's dual role as identity provider + auth gateway lowers the marginal
cost of adding auth protection to new services:

- **Zero-cost auth for new services.** Today, protecting a new web UI
  requires deploying another oauth2-proxy instance (service, sops secret,
  OIDC client registration, systemd config). With Authelia, it's an
  `auth_request` directive in nginx plus one access control rule in the
  central Authelia config. No new service, no new secrets, no new client
  registration.

- **Centralized access control as code.** Access control policy is currently
  scattered across oauth2-proxy `--allowed-group` flags on different hosts.
  With Authelia, a single `access_control.rules` block maps domains/paths to
  policies and groups — reviewable, diffable, version-controlled in Nix.

- **Candidates for auth protection.** Internal web UIs that currently lack
  auth gating because the overhead of another oauth2-proxy was too high:
  - Attic web UI on ardent
  - Forgejo on creil (could add Authelia as external OIDC provider)
  - Any future web service gets auth essentially for free

- **Future: dynamic users via LDAP.** If the homelab ever needs runtime user
  management (self-service signup, admin UI for adding users), the path is
  adding a lightweight LDAP server like lldap (~30MB RAM) and pointing
  Authelia's backend at it. Authelia's config and all its consumers stay
  unchanged — only the authentication backend switches from file to LDAP.

## Current Keycloak consumers

| Consumer                   | Host      | Auth flow              | What it checks            | Authelia support |
| -------------------------- | --------- | ---------------------- | ------------------------- | ---------------- |
| oauth2-proxy (external)    | langport  | Auth Code              | Group membership          | Native (replaces oauth2-proxy entirely) |
| oauth2-proxy (internal)    | phantasma | Auth Code              | Group `admin`             | Native (replaces oauth2-proxy entirely) |
| step-ca OIDC provisioner   | basel     | Auth Code + localhost  | Token issuer, signature   | Yes (standard OIDC discovery + JWKS) |
| Perses OIDC                | tharbad   | Auth Code              | OIDC groups               | Yes (standard OIDC client) |
| deployd-api JWT validation | roer      | Bearer token (JWKS)    | Group `deploy`, issuer    | Yes (standard JWKS endpoint) |
| cc-sandbox CLI             | client    | Device Code (RFC 8628) | Group `deploy`            | **No** — needs migration to Auth Code + PKCE |

### Consumer not affected by this migration

| Consumer                 | Why unaffected                                              |
| ------------------------ | ----------------------------------------------------------- |
| Woodpecker ↔ Forgejo     | Uses Forgejo-native OAuth2, not Keycloak                    |
| NATS fleet activation    | Uses NKey credentials (Ed25519), no OIDC                    |
| Attic binary cache       | Uses Attic tokens, no OIDC                                  |
| AI agent Forgejo access  | Uses personal access tokens or Forgejo-native OAuth2        |
| CI/CD SSH certificates   | Planned `client_credentials` path is obsolete — fleet activation uses NATS pull model, not SSH deploys |

## Gap analysis

### Device code flow (cc-sandbox)

**Status:** Only real gap. cc-sandbox currently uses RFC 8628 device code flow.
Authelia does not support this grant type.

**Resolution:** Migrate cc-sandbox to Authorization Code + PKCE with localhost
redirect. This is the standard pattern for CLI tools (it's what `step ssh login`,
`gh auth login`, and `gcloud auth login` all use). The change:

1. cc-sandbox starts a temporary HTTP listener on `127.0.0.1:<random-port>`
2. Opens the user's browser to the Authelia authorization endpoint
3. User authenticates in the browser
4. Authelia redirects to `http://127.0.0.1:<port>/callback` with the auth code
5. cc-sandbox exchanges the code for tokens

This is a better UX than device code flow (no manual code entry, single browser
interaction) and is more widely supported across OIDC providers.

### Client credentials grant (cicd-deploy)

**Status:** Not a gap. The `cicd-deploy` client in `homelab-realm.json` has
`serviceAccountsEnabled: true` but is not actively used anywhere. The CI/CD
fleet activation pipeline uses NATS NKey credentials, not OIDC. The SSH
certificate plan's client credentials path for CI/CD deploys is superseded by
the NATS-based pull model.

If a future CI/CD workflow needs machine-to-machine OIDC auth, evaluate at
that time. The likely alternative would be a long-lived API token or a
pre-provisioned JWT — but there's no current or planned need.

### Admin console

**Status:** Not a gap. Authelia has no admin console. User and client
configuration is YAML, managed declaratively through Nix. This is actually
better for this project — the user database becomes version-controlled config
rather than mutable PostgreSQL state.

### Multi-realm / multi-tenancy

**Status:** Not a gap. The homelab uses a single `homelab` realm. Authelia's
single-domain model is sufficient.

## User database

Authelia supports two backends: file-based (YAML) or LDAP. For this homelab's
scale (a handful of users), the file backend is the right choice.

The user database is a YAML file declaring users, hashed passwords, groups,
and email. Authelia hot-reloads on file changes.

**The user database file must be sops-encrypted.** It contains password hashes
and email addresses — not suitable for a public repo. The structural Authelia
config (OIDC clients, access control rules, session settings) stays in Nix as
normal public config, same as `homelab-realm.json` today. Only the file with
actual user credentials is encrypted.

```nix
# In messeldam's Authelia module:
services.authelia.instances.main.settings.authentication_backend.file.path =
  config.sops.secrets."authelia-users".path;
```

The sops-encrypted user database YAML:

```yaml
# hosts/calvard/microvm/guests/messeldam/secrets/authelia-users.yaml
users:
  admin:
    displayname: "Admin"
    email: "admin@mutantmell.net"
    groups:
      - admin
      - deploy
    password: "$argon2id$..."
  media-user:
    displayname: "Media User"
    email: "media@mutantmell.net"
    groups:
      - media-users
    password: "$argon2id$..."
```

Password hashes can be generated with `authelia crypto hash generate argon2`.

## OIDC client configuration

Authelia OIDC clients are declared in the main config YAML:

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: step-ca
        client_name: "SSH Certificate CA"
        client_secret: "$pbkdf2-sha512$..."  # from sops
        redirect_uris:
          - "http://127.0.0.1:10000"
        scopes: [openid, profile, email, groups]
        grant_types: [authorization_code]
        response_types: [code]

      - client_id: perses
        client_name: "Perses Monitoring"
        client_secret: "$pbkdf2-sha512$..."
        redirect_uris:
          - "https://tharbad.internal/api/auth/providers/oidc/authelia/callback"
        scopes: [openid, profile, email, groups]
        grant_types: [authorization_code]
        response_types: [code]

      - client_id: deployd-api
        client_name: "deployd Container API"
        # Bearer-only validation — deployd-api only checks JWKS, doesn't initiate flows
        # Still needs a client registration for Authelia to include it in token audience
        client_secret: "$pbkdf2-sha512$..."
        scopes: [openid, groups]
        grant_types: [authorization_code]
        response_types: [code]

      - client_id: cc-sandbox
        client_name: "Claude Code Sandbox CLI"
        public: true
        redirect_uris:
          - "http://127.0.0.1:*"
        scopes: [openid, profile, email, groups]
        grant_types: [authorization_code]
        pkce_challenge_method: S256
        require_pkce: true
```

## Authelia as nginx auth gateway (replaces oauth2-proxy)

Authelia natively supports nginx's `auth_request` directive, eliminating the
need for oauth2-proxy as a separate service. This simplifies langport and
phantasma by removing a dependency.

### nginx integration pattern

```nginx
# Internal auth verification endpoint
location /authelia {
    internal;
    proxy_pass http://authelia:9091/api/authz/auth-request;
    proxy_set_header X-Original-URL $scheme://$host$request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Protected location
location / {
    auth_request /authelia;
    auth_request_set $user $upstream_http_remote_user;
    error_page 401 =302 https://auth.mutantmell.net/?rd=$scheme://$host$request_uri;
    proxy_pass https://upstream;
}
```

Authelia's access control rules replace oauth2-proxy's `--allowed-group` flag:

```yaml
access_control:
  default_policy: deny
  rules:
    # Internal admin UIs — admin group only
    - domain: phantasma.internal
      policy: two_factor
      subject:
        - "group:admin"

    # External media services — any authenticated user
    - domain: mutantmell.net
      policy: one_factor

    # Auth domain itself
    - domain: auth.mutantmell.net
      policy: bypass
```

## Architecture

### Deployment option: reuse messeldam microVM

Rename the purpose of messeldam from "Keycloak OIDC" to "Authelia OIDC".
Same network position (vINFRA, same IP), same DNS (`auth.mutantmell.net`),
dramatically reduced resource footprint.

```
messeldam (vINFRA, 10.97.11.6)
  ├── Authelia (OIDC provider + auth gateway backend)
  ├── nginx (TLS termination, same step-ca ACME setup)
  └── SQLite (session/OIDC state — tiny, no PostgreSQL)
```

Resource reduction:
- `microvm.mem`: 2048 → 512
- `microvm.vcpu`: 2 → 1
- Persist volume: 100 GB → 1 GB (drop PostgreSQL, keep small SQLite + Authelia state)
- Remove: JVM, PostgreSQL, `JAVA_OPTS_APPEND` tuning

### What stays the same

- Hostname: messeldam
- IP: 10.97.11.6 (vINFRA)
- DNS: auth.mutantmell.net
- TLS: step-ca ACME (same bootstrap/renewal systemd services)
- Firewall: same egress rules (DNS, HTTP/HTTPS, basel for ACME, tharbad for Loki)
- Forward rules: langport → messeldam, tharbad → messeldam, phantasma �� messeldam (all unchanged)

---

## Migration phases

### Phase 0: cc-sandbox auth code migration (pre-requisite)

Migrate cc-sandbox from device code flow to authorization code + PKCE with
localhost redirect. This can be done and tested against the existing Keycloak
deployment before any Authelia work begins.

1. Register a new `cc-sandbox-v2` client in Keycloak with:
   - `publicClient: true`
   - `standardFlowEnabled: true` (authorization code)
   - Redirect URIs: `http://127.0.0.1:*`
   - PKCE required
2. Update `packages/cc-sandbox/cc_sandbox.py` auth module:
   - Replace device code flow with auth code + PKCE + localhost listener
   - Keep token caching and refresh logic
3. Test against Keycloak to verify the flow works
4. Remove the old `cc-sandbox` client from `homelab-realm.json`

**Validation:** cc-sandbox `login` command opens browser, completes auth,
receives token with correct `groups` claim.

### Phase 1: Deploy Authelia alongside Keycloak (coexistence)

Run Authelia on messeldam alongside Keycloak temporarily. Authelia listens on
a different port. This allows testing each consumer migration individually
without downtime.

1. Add Authelia NixOS module to messeldam:
   ```nix
   services.authelia.instances.main = {
     enable = true;
     secrets = { /* sops references */ };
     settings = { /* config as described above */ };
   };
   ```
2. Configure Authelia with:
   - User database (YAML, matching current Keycloak users/groups)
   - OIDC clients (matching current Keycloak clients)
   - Access control rules
   - Session/storage configuration (SQLite)
3. Expose Authelia on a secondary internal-only hostname (e.g., `authelia.internal`)
   via a second nginx vhost on messeldam
4. Keep Keycloak running on `auth.mutantmell.net` — all existing consumers
   continue working unchanged

**Validation:** Authelia responds to OIDC discovery at
`https://authelia.internal/.well-known/openid-configuration` and JWKS at
`https://authelia.internal/jwks.json`.

### Phase 2: Migrate consumers one at a time

Migrate each consumer from Keycloak to Authelia, testing after each switch.
Order from lowest-risk to highest-risk:

#### 2a. Perses (tharbad) — lowest risk, monitoring only

Update `hosts/calvard/microvm/guests/tharbad/modules/perses.nix`:
- Change `issuer` URL from `https://auth.mutantmell.net/realms/homelab` to
  `https://authelia.internal`
- Change `slug_id` and `name` from `keycloak` to `authelia`
- Update `redirect_uri` callback path if needed
- Update client secret in sops

**Validation:** Log into Perses via OIDC, verify admin role assignment.

#### 2b. deployd-api (roer) — low risk, JWT validation only

Update `packages/deployd-api/src/config.rs` (or deployment config):
- Change `oidc_issuer` to `https://authelia.internal`
- JWKS URL auto-discovered from issuer

**Validation:** cc-sandbox (pointed at Authelia) deploys a container
successfully, deployd-api validates the JWT and accepts the `deploy` group.

#### 2c. cc-sandbox — moderate risk, user-facing CLI

Update `home/modules/cc-sandbox.nix`:
- Change `authBaseUrl` to the Authelia issuer URL

**Validation:** Full cc-sandbox deploy cycle works end-to-end.

#### 2d. oauth2-proxy on phantasma — moderate risk, internal only

Replace oauth2-proxy with Authelia's native nginx `auth_request` integration.

Update `hosts/thebeyond/microvm/guests/phantasma/modules/proxy.nix`:
- Remove `services.oauth2-proxy` configuration
- Replace with Authelia `auth_request` in nginx config
- Authelia runs on messeldam; phantasma's nginx sends auth_request to
  `https://authelia.internal/api/authz/auth-request`

**Validation:** Access Adguard Home at `phantasma.internal/adguard/`,
get redirected to Authelia login, authenticate, access granted for
admin group users.

#### 2e. step-ca OIDC provisioner (basel) — higher risk, SSH certs

Update `hosts/calvard/microvm/guests/basel/modules/step-ca.nix`:
- Change OIDC provisioner `configurationEndpoint` to
  `https://authelia.internal/.well-known/openid-configuration`
- Change provisioner `name` from `keycloak` to `authelia`
- Update `clientID` and add client secret for Authelia
- Update SSH template if it references Keycloak-specific claim paths

**Validation:** `step ssh login --provisioner authelia` completes successfully,
receives a valid SSH certificate with correct principals.

Note: This also requires updating `modules/common/ssh-cert-client.nix` to
change `provisioner = "keycloak"` to `provisioner = "authelia"`.

#### 2f. oauth2-proxy on langport — highest risk, external-facing

Replace oauth2-proxy with Authelia's native nginx `auth_request` integration.

Update `hosts/calvard/microvm/guests/langport/proxy.nix`:
- Remove `services.oauth2-proxy` configuration
- Add Authelia `auth_request` to the `mutantmell.net` vhost
- Switch `auth.mutantmell.net` vhost from proxying Keycloak to proxying Authelia

**Validation:** Access `https://mutantmell.net` from external network,
get redirected to `auth.mutantmell.net` (now Authelia), authenticate,
access Jellyfin.

### Phase 3: Cutover — remove Keycloak

Once all consumers are on Authelia and validated:

1. Update `auth.mutantmell.net` to point at Authelia (swap the primary nginx
   vhost on messeldam from Keycloak to Authelia)
2. Update all consumers from `https://authelia.internal` to
   `https://auth.mutantmell.net` (final issuer URL)
3. Remove Keycloak from messeldam:
   - Delete `modules/keycloak.nix`
   - Delete `homelab-realm.json`
   - Remove PostgreSQL persistence directory from `environment.persistence`
   - Remove `keycloak_password_file` and `keycloak_admin_password` from sops
   - Remove `JAVA_OPTS_APPEND` environment variable
   - Remove `systemd.services.keycloak` overrides (before/requiredBy nginx,
     EnvironmentFile for admin env)
   - Remove `sops.templates."keycloak-admin-env"`
4. Reduce messeldam resources:
   - `microvm.mem`: 2048 → 512
   - `microvm.vcpu`: 2 → 1
   - Shrink or recreate persist volume (100 GB → 1 GB)
5. Remove boot-time workarounds that existed for Keycloak's slow JVM startup:
   - `step-ca-oidc-retry` service on basel
     (`hosts/calvard/microvm/guests/basel/modules/step-ca.nix`)
   - `RestartSec`/`StartLimitBurst` retry config on oauth2-proxy in langport
     (`hosts/calvard/microvm/guests/langport/proxy.nix`) — oauth2-proxy
     itself is also removed in step 6
   - `RestartSec`/`StartLimitBurst` retry config on oauth2-proxy in phantasma
     (`hosts/thebeyond/microvm/guests/phantasma/modules/proxy.nix`) —
     oauth2-proxy itself is also removed in step 6
6. Remove oauth2-proxy entirely from phantasma and langport:
   - `services.oauth2-proxy` config blocks
   - `oauth2-proxy-internal-keyfile` sops secret on phantasma
   - `oauth-2-proxy-keyfile` sops secret on langport
   - All `oauth2/` nginx location blocks (replaced by `auth_request` to
     Authelia in Phase 2d/2f)
7. Update `lib/common/data/network.nix` comment:
   `messeldam = 6; # Authelia OIDC (calvard)`
8. Update documentation and plan references

### Phase 4: Post-migration cleanup

1. Update `llm-notes/done/keycloak-oauth-oidc-plan.md` status to note
   replacement by Authelia
2. Update `llm-notes/feature-roadmap-analysis.md` Step 4 (Keycloak OIDC)
   to reflect Authelia
3. Update `llm-notes/wip/deployd-integration.md` auth references
4. Update `llm-notes/wip/headscale-integration-plan.md` Keycloak references
5. Verify all `oauth2-proxy` references are removed from the codebase

## Rollback plan

During the coexistence phase (Phases 1–2), rollback is trivial: point the
consumer back at Keycloak's issuer URL. Keycloak remains running and
unchanged until Phase 3.

If Phase 3 (Keycloak removal) needs to be rolled back: Keycloak's
`homelab-realm.json` is in git, PostgreSQL data is on the persist volume
(not yet shrunk). Re-enable the Keycloak module and redeploy.

After the persist volume is shrunk, rollback requires re-provisioning
Keycloak from scratch using the realm JSON — which is exactly how it was
originally bootstrapped.

## MFA considerations

Authelia supports TOTP and WebAuthn natively. The current Keycloak setup
plans MFA for the admin group. Authelia's access control rules handle this
with the `two_factor` policy on admin-only resources:

```yaml
access_control:
  rules:
    - domain: phantasma.internal
      policy: two_factor
      subject: ["group:admin"]
```

Configure TOTP or WebAuthn enrollment after migration. Authelia's MFA
enrollment is self-service via its web portal.

## Secrets

New sops secrets needed on messeldam:
- Authelia JWT secret (signs session tokens)
- Authelia storage encryption key (encrypts SQLite data at rest)
- Authelia OIDC HMAC secret
- Authelia OIDC private key (RSA or ECDSA, for signing OIDC tokens)
- Per-client secrets (hashed, embedded in config — or via sops templates)

Secrets removed after migration:
- `keycloak_password_file` (PostgreSQL password)
- `keycloak_admin_password`
- oauth2-proxy keyfiles on langport and phantasma

## Follow-up work (post-migration)

These items are orthogonal to the migration itself but represent gaps in the
homelab's overall AuthN/AuthZ story that Authelia makes easier to address.

### F1. MFA enrollment for admin accounts

MFA is planned but not deployed. Admin accounts accessing infrastructure UIs
(Adguard, Perses, step-ca admin) should require a second factor. Authelia
supports TOTP and WebAuthn natively with a self-service enrollment portal.

After migration, configure `two_factor` policy on admin-only domains and
complete TOTP or WebAuthn enrollment for all admin users. This is the single
biggest remaining AuthN gap.

### F2. Auth audit trail via Loki

There is no centralized record of "user X authenticated at time T and accessed
service Y." Authelia logs authentication events (successes, failures, MFA
challenges) to stdout/file. Feed these to Loki via promtail — the same pattern
every other service on messeldam already uses (`promtail-client.enable = true`).

This becomes more important once friends are on the network (headscale plan)
and the question "who accessed what, when" has real operational value. The
friend-access report's threat model specifically calls out credential
compromise scenarios where audit trails inform incident response.

### F3. Headscale plan update (Keycloak → Authelia)

The headscale integration plan (`llm-notes/wip/headscale-integration-plan.md`)
references Keycloak throughout — OIDC client registration, cross-zone firewall
rules to Keycloak, architecture diagrams. All Keycloak references should be
updated to Authelia. The OIDC flows are identical (authorization code grant),
so this is a terminology update, not an architectural change.

Note: the friend-access report recommends pre-authkeys for friend enrollment
(no OIDC for friends), so the headscale OIDC integration only affects *admin*
login to headscale, not friend access.

### F4. Token revocation and incident response procedure

If a user's OIDC session or token is compromised, what's the response?
Authelia supports session revocation (delete from SQLite session store), and
short token lifetimes limit exposure window. But there is no documented
incident response procedure.

Document a runbook covering:
- How to revoke a specific user's sessions (Authelia SQLite)
- How to disable a user account (remove from sops user database, redeploy)
- How to rotate OIDC signing keys (force all tokens to re-validate)
- For headscale (future): how to revoke a friend's node identity

This matters more once friends are on the network — the friend-access report's
threat model is built around the credential-compromise case.

### F5. Conscious decision: no mTLS for internal service communication

Internal services (Prometheus scraping, Loki log ingestion, step-ca ACME)
authenticate via TLS server certificates but not mutual TLS. Any host on the
same VLAN can reach these services; the zone firewall is the primary access
control.

This is an acceptable tradeoff for a homelab — mTLS between every service
would add significant complexity (client cert provisioning, rotation, trust
store management) for marginal security gain when VLAN boundaries are already
enforced by the router's nftables rules. Documenting this as a conscious
decision rather than an oversight.

If the threat model changes (e.g., multi-tenant VLANs, untrusted workloads
on the same zone as infrastructure services), revisit mTLS. The step-ca
infrastructure to support it already exists.

## Implementation sequence

```
Phase 0 ──── cc-sandbox auth code migration (can start immediately)
              │
Phase 1 ──── Deploy Authelia on messeldam alongside Keycloak
              │
Phase 2a ─── Perses → Authelia
Phase 2b ─── deployd-api → Authelia
Phase 2c ─── cc-sandbox → Authelia
Phase 2d ─── phantasma oauth2-proxy → Authelia auth_request
Phase 2e ─── step-ca OIDC → Authelia
Phase 2f ─── langport oauth2-proxy → Authelia auth_request
              │
Phase 3 ──── Remove Keycloak, shrink messeldam
              │
Phase 4 ──── Documentation cleanup
              │
Follow-ups (independent, post-migration):
F1 ────────── MFA enrollment for admin accounts
F2 ────────── Auth audit trail via Loki
F3 ────────── Headscale plan update (Keycloak → Authelia references)
F4 ────────── Token revocation / incident response runbook
F5 ────────── Document no-mTLS as conscious decision
```

Phases 2a–2f are sequential (one consumer at a time, validate between each).
Phase 0 is independent and can be done in parallel with Phase 1.
Follow-ups F1–F5 are independent of each other and can be done in any order.
