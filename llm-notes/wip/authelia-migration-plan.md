# Authelia Migration Plan: Replace Keycloak with Authelia

Plan date: 2026-04-19
Refreshed: 2026-06-02
Moved to wip: 2026-06-02

**Phase status:**

- Phase 0 — N/A (cc-sandbox retired)
- Phase 1 — COMPLETE, deployed + validated 2026-06-03 (discovery, JWKS, and
  portal login all confirmed against lldap; see "Phase 1 — implementation
  notes" below). Keycloak still running unchanged on auth.mutantmell.net.
- Phase 1 follow-up — `jellyfin` LDAP bind user now auto-seeded by
  lldap-bootstrap (deployed 2026-06-03), ahead of Phase 2d.
- Phase 2a (Perses) — COMPLETE, deployed (commit `1e76e1a`). Perses OIDC points
  at Authelia.
- Phase 2b (phantasma) — repo-COMPLETE, pending deploy. Became a **removal**,
  not a migration: AdGuard Home was retired in the blocky migration, so
  phantasma's oauth2-proxy/nginx stack guarded nothing. proxy.nix, the
  oauth2-proxy secret ref, the dead messeldam access_control rule, and the
  stale Adguard comments are all removed. Pre-removal checks (no
  phantasma→messeldam forward rule; blocky metrics never traversed nginx) both
  cleared.
- Phase 2c (step-ca OIDC, basel) — split into two coexistence sub-steps for a
  no-revert rollback path:
  - **2c step i — repo-COMPLETE, pending deploy.** basel runs the `keycloak`
    and `authelia` OIDC provisioners **side by side** (both `clientID=step-ca`,
    sharing loopback `127.0.0.1:10000`; step-cli binds it per login so no
    conflict). The `ssh-cert-client.nix` default stays `keycloak`, so the
    default `step ssh login` path is unchanged; Authelia is verified explicitly
    via `step ssh login --provisioner authelia`. `step-ca-oidc-retry` now waits
    on both discovery endpoints and restarts unless both provisioners init'd
    cleanly. Fall back by just not using `--provisioner authelia` — no revert.
  - **2c step ii — NOT STARTED.** Once Authelia is verified: remove the
    `keycloak` provisioner from basel and flip the `ssh-cert-client.nix` default
    to `authelia`.
  - **Design correction (applies to both sub-steps):** Phase 1 registered the
    `step-ca` client as confidential, but step-ca is a native-app **public**
    client (step-cli does authorization-code+PKCE on a loopback redirect, and
    step-ca republishes any provisioner secret via its public `/provisioners`
    API — RFC 8252). Keycloak had it as `publicClient: true`. So 2c flips the
    Authelia client to `public: true` + `require_pkce`/`S256`, drops the
    `authelia-oidc-step-ca-secret-hash` sops secret, and basel needs no client
    secret. SSH OIDC template needed no change (`.Token.groups` is emitted by
    both providers via the `groups` scope). `step-ca-oidc-retry` stays (see
    Phase 3 note below).
- Phase 2d–2e — NOT STARTED (Jellyfin LDAP, langport).
- Phase 3 — NOT STARTED (cutover, remove Keycloak)
- Phase 4 — NOT STARTED (doc cleanup)
- F1–F5 — NOT STARTED (independent follow-ups)

> **Execution approach: repo changes only — operator deploys.** Claude makes
> all the Nix/config changes for each phase and hands the operator the
> `nixos-rebuild`/validation commands to run; Claude does not run deploys
> against live hosts. This is live auth for the whole homelab, so each consumer
> migration lands as its own reviewable commit and is validated before the next.
>
> **Scope change (post deployd decommission, 2026-06-02):** deployd and
> cc-sandbox were retired (see
> [`llm-notes/done/k3s-deployd-migration-plan.md`](../done/k3s-deployd-migration-plan.md)).
> Two consumers this plan originally migrated are **gone**, not migrated:
> - **deployd-api (roer)** — host removed; no OIDC client needed.
> - **cc-sandbox CLI** — retired; no OIDC client needed. Phase 0 (its
>   auth-code refactor) is therefore moot.
>
> The `deploy` group is no longer consumed by anything today (its only users
> were deployd-api and cc-sandbox). It is kept in lldap as a forward-looking
> group for future CI/CD machine identity, but no access-control rule depends
> on it yet.

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

- **Unified identity for LDAP-native services.** lldap provides a single
  user directory that both Authelia (via LDAP backend) and services without
  OIDC support (Jellyfin via official LDAP plugin) query directly. Users
  get one set of credentials that works everywhere — Authelia handles
  OIDC-capable services, Jellyfin authenticates against LDAP natively.
  See "User database" section below.

## Current Keycloak consumers

| Consumer                   | Host      | Auth flow             | What it checks          | Authelia support                           |
| -------------------------- | --------- | --------------------- | ----------------------- | ------------------------------------------ |
| oauth2-proxy (external)    | langport  | Auth Code             | Group membership        | Native (replaces oauth2-proxy entirely)    |
| oauth2-proxy (internal)    | phantasma | Auth Code             | Group `admin`           | Native (replaces oauth2-proxy entirely)    |
| step-ca OIDC provisioner   | basel     | Auth Code + localhost | Token issuer, signature | Yes (standard OIDC discovery + JWKS)       |
| Perses OIDC                | tharbad   | Auth Code             | OIDC groups             | Yes (standard OIDC client)                 |
| Jellyfin (built-in auth)   | oracion   | Local accounts        | Jellyfin-internal users | Migrated to lldap via official LDAP plugin |

> ~~deployd-api JWT validation (roer)~~ and ~~cc-sandbox CLI~~ were consumers in
> the original plan; both were retired in the deployd decommission (2026-06-02)
> and are no longer migrated.

### Consumer not affected by this migration

| Consumer                | Why unaffected                                                                                         |
| ----------------------- | ------------------------------------------------------------------------------------------------------ |
| Woodpecker ↔ Forgejo    | Uses Forgejo-native OAuth2, not Keycloak                                                               |
| NATS fleet activation   | Uses NKey credentials (Ed25519), no OIDC                                                               |
| Attic binary cache      | Uses Attic tokens, no OIDC                                                                             |
| AI agent Forgejo access | Uses personal access tokens or Forgejo-native OAuth2                                                   |
| CI/CD SSH certificates  | Planned `client_credentials` path is obsolete — fleet activation uses NATS pull model, not SSH deploys |

## Gap analysis

### Device code flow (cc-sandbox) — N/A

cc-sandbox was retired in the deployd decommission (2026-06-02), so its
device-code / OIDC-discovery requirements no longer constrain provider choice.
(For the record, Authelia v4.39.0 did ship RFC 8628 device-code support, so a
future headless OIDC client would be covered.)

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

## User database: lldap

Authelia supports two backends: file-based (YAML) or LDAP. Despite the small
user count, we deploy **lldap** (lightweight LDAP server) from the start for
one reason: **Jellyfin's OIDC support is an unofficial third-party plugin
(AGPL, rough edges, poor mobile/TV client support), while its LDAP plugin is
official and works with all clients.** Using lldap as the shared user directory
lets both Authelia and Jellyfin authenticate against the same source of truth
via their respective official/reliable integration paths.

### Architecture

lldap is a Rust binary (~30MB RAM) with a SQLite database. It provides:

- **LDAP interface** (port 3890) — queried by Authelia and Jellyfin
- **Web UI** (port 17170) — for user/group management, restricted to vMGMT/vHOME

```
lldap (data store)
  ├── LDAP port 3890 ← Authelia (authentication + group lookup)
  ├── LDAP port 3890 ← Jellyfin (official LDAP plugin, all clients)
  └── Web UI port 17170 ← admin only (vMGMT/vHOME network restriction)
```

The security boundary is clean: lldap's LDAP port is a read-only query
interface (Authelia binds to verify passwords, Jellyfin looks up users).
lldap's web UI is the mutation surface (create/delete users, change groups)
and is network-restricted to trusted zones — a completely separate protocol
on a separate port, unlike Keycloak's admin console which shared a port with
user-facing auth.

### Deployment: co-located on messeldam

lldap runs on messeldam alongside Authelia. Both are lightweight Go/Rust
binaries with SQLite — no need for a separate microVM.

Authelia config:

```yaml
authentication_backend:
  ldap:
    address: ldap://127.0.0.1:3890
    implementation: lldap
    base_dn: dc=mutantmell,dc=net
    users_filter: "(&({username_attribute}={input})(objectClass=person))"
    groups_filter: "(member={dn})"
    user: uid=authelia,ou=people,dc=mutantmell,dc=net
    password: # from sops
```

Jellyfin LDAP plugin config (via Jellyfin admin dashboard):

```
LDAP Server: messeldam.internal
Port: 3890
Base DN: dc=mutantmell,dc=net
User Filter: (objectClass=person)
```

### Users and groups

Managed via lldap's web UI or its API. Groups mirror the current structure:

| Group         | Purpose                     | Used by                                |
| ------------- | --------------------------- | -------------------------------------- |
| `admin`       | Full access to everything   | Authelia access control, step-ca SSH   |
| `deploy`      | CI/CD and deployment        | none yet (was deployd-api/cc-sandbox; kept for future CI/CD) |
| `media-users` | Jellyfin and media services | Jellyfin LDAP, Authelia access control |

### Secrets

lldap needs:

- Admin password (sops, for initial setup and lldap web UI login)
- Authelia bind password (sops, for Authelia's LDAP queries)
- Jellyfin bind password (sops, for Jellyfin's LDAP queries — can be a
  read-only service account)

### Persistence

lldap's SQLite database stores users, groups, and password hashes. This is
the **only mutable auth state** in the system and needs persistence +
backup consideration. Small (< 1 MB for homelab scale).

Added to messeldam's `environment.persistence."/persist"`:

```nix
{ directory = "/var/lib/lldap"; user = "lldap"; group = "lldap"; }
```

### Network restrictions

- LDAP port (3890): accessible from messeldam localhost (Authelia) and
  oracion (Jellyfin). Firewall rule: oracion → messeldam TCP 3890.
- Web UI port (17170): restricted to vHOME (admin browser access).
  Not exposed to vDMZ or the internet.

## OIDC client configuration

Authelia OIDC clients are declared in the main config YAML:

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: step-ca
        client_name: "SSH Certificate CA"
        client_secret: "$pbkdf2-sha512$..." # from sops
        redirect_uris:
          - "http://127.0.0.1:10000"
        scopes: [openid, profile, email, groups]
        grant_types: [authorization_code]
        response_types: [code]

      - client_id: perses
        client_name: "Perses Monitoring"
        client_secret: "$pbkdf2-sha512$..."
        redirect_uris:
          - "https://perses.internal/api/auth/providers/oidc/authelia/callback"
        scopes: [openid, profile, email, groups]
        grant_types: [authorization_code]
        response_types: [code]
```

Only two OIDC clients remain (step-ca, perses). The `deployd-api` and
`cc-sandbox` clients from the original plan are dropped — both consumers were
retired in the deployd decommission (2026-06-02).

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
  ├── lldap (LDAP user directory — queried by Authelia and Jellyfin)
  ├── nginx (TLS termination, same step-ca ACME setup)
  └── SQLite ×2 (Authelia session/OIDC state + lldap user directory)
```

Resource reduction:

- `microvm.mem`: 2048 → 512 (Authelia ~50MB + lldap ~30MB + nginx, well within 512MB)
- `microvm.vcpu`: 2 → 1
- Persist volume: 100 GB → 1 GB (drop PostgreSQL, keep small SQLite databases)
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

### Phase 0: cc-sandbox auth code migration — N/A (cc-sandbox retired)

Originally a prerequisite that refactored cc-sandbox to provider-agnostic OIDC
discovery. cc-sandbox was retired in the deployd decommission (2026-06-02), so
this phase no longer applies and there is no remaining client to migrate.

### Phase 1: Deploy Authelia + lldap alongside Keycloak (coexistence)

Run Authelia and lldap on messeldam alongside Keycloak temporarily. Authelia
listens on a different port. This allows testing each consumer migration
individually without downtime.

1. Deploy lldap on messeldam:
   - Add lldap service (NixOS module or systemd service)
   - Configure base DN (`dc=mutantmell,dc=net`)
   - Create users and groups matching current Keycloak realm
     (admin, media-users, deploy groups; same user accounts)
   - Create read-only service accounts for Authelia and Jellyfin
   - Restrict web UI port (17170) to vHOME via firewall
   - Add lldap SQLite to persistence
2. Add Authelia NixOS module to messeldam:
   ```nix
   services.authelia.instances.main = {
     enable = true;
     secrets = { /* sops references */ };
     settings = { /* config as described above */ };
   };
   ```
3. Configure Authelia with:
   - LDAP backend pointing at localhost lldap
   - OIDC clients (matching current Keycloak clients)
   - Access control rules
   - Session/storage configuration (SQLite)
4. Expose Authelia on a secondary internal-only hostname (e.g., `authelia.internal`)
   via a second nginx vhost on messeldam
5. Keep Keycloak running on `auth.mutantmell.net` — all existing consumers
   continue working unchanged

**Validation:**

- lldap web UI accessible from vHOME, users and groups created
- Authelia responds to OIDC discovery at
  `https://authelia.internal/.well-known/openid-configuration` and JWKS at
  `https://authelia.internal/jwks.json`
- Authelia login works with lldap-stored credentials

### Phase 1 — implementation notes (2026-06-02)

Repo changes landed (one commit, all on messeldam — Keycloak untouched):

- `modules/lldap.nix` — lldap service, base DN `dc=mutantmell,dc=net`, admin
  password from sops via systemd `LoadCredential` (lldap is a DynamicUser),
  SQLite persisted at `/var/lib/private/lldap`. Plus a `lldap-bootstrap`
  oneshot that declaratively seeds the base groups (`admin`, `media-users`,
  `deploy`) and the read-only `authelia` bind user (in `lldap_strict_readonly`,
  password synced from sops) via `lldap-cli` — so the directory is usable from
  a cold boot with no manual web-UI step.
- `modules/authelia.nix` — `services.authelia.instances.main`: lldap auth
  backend, SQLite storage, filesystem notifier, `access_control`, the
  `auth-request` authz endpoint (ready for Phase 2e — langport; 2b became a
  removal, no longer an auth_request consumer), both OIDC clients
  (step-ca, perses) via a sops template, and an `authelia.internal` nginx
  vhost with step-ca ACME. SQLite + ACME state persisted. `authelia-main`
  `requires`/`after` `lldap-bootstrap` so it never starts before the bind user
  exists (its LDAP startup check is fatal). NTP startup check disabled (egress
  blocks public NTP by design; host syncs time via the gateway).
- `sops.nix` — new secret references + an operator runbook (in comments) for
  generating each value.
- `default.nix` — imports the two new modules.
- `network.nix` — `authelia.internal[.mutantmell.net]` aliases on messeldam.

**Deviations from the plan as written, and why:**

1. **lldap web UI at `ldap.internal`, management-zone only; LDAP port stays
   localhost.** The registry has no `vHOME`/`vINFRA` zone (loose names in this
   doc — messeldam is in `management`). The web UI binds to localhost and is
   fronted by nginx at `https://ldap.internal`, restricted via L7 `allow`/`deny`
   to the management subnet (pulled from the registry, not hardcoded). messeldam
   does its own source filtering because langport (DMZ) can reach it directly.
   The LDAP port (3890) stays localhost-only until Phase 2d rebinds it and adds
   the oracion→messeldam:3890 rules for Jellyfin. No new firewall ports (443/80
   already open). Caveat: the `allow` list covers the management subnet only —
   an operator browsing from a wg-vpn tunnel address would be denied; add the
   wg-vpn subnet to the `allow` list if that's the access path.

2. **Both OIDC clients defined now, not deferred to their Phase 2 commits.**
   Keeps Phase 2a/2c pure consumer-side switches against an already-proven
   provider. Costs the operator two client-secret hashes up front.

3. **`authelia.internal/jwks.json`** — the real path is
   `/.well-known/openid-configuration` → `jwks_uri`
   (`/api/oidc/jwks` in Authelia), not `/jwks.json`. Validate via the
   discovery doc's `jwks_uri`.

4. **Portal/issuer is the FQDN `authelia.internal.mutantmell.net`, not the
   short `authelia.internal`.** Authelia rejects a single-label cookie domain
   ("must have at least a single period"), so the session cookie domain is
   `internal.mutantmell.net` and the portal/issuer must live under it. The
   short `authelia.internal` stays a resolving alias on the vhost, but
   interactive login and the OIDC issuer must use the FQDN — consumers
   (perses 2a, step-ca 2c) point their issuer at
   `https://authelia.internal.mutantmell.net`. OIDC consumers' own callback
   hostnames (e.g. `perses.internal`) are unaffected — the cookie domain only
   constrains the portal and, later, auth_request-protected hosts, which must
   be addressed as `*.internal.mutantmell.net`.

**Operator steps before deploy:**

1. Generate + store the new sops secrets — commands are in
   `hosts/calvard/microvm/guests/messeldam/secrets/secrets.yaml`'s sibling
   `sops.nix` comment block. Keep the two OIDC client *plaintexts* for
   Phase 2a (perses) / 2c (step-ca); store only the hashes here.
2. Deploy phantasma first (serves the internal DNS zone, so `authelia.internal`
   and `ldap.internal` resolve), then messeldam.
3. The base groups and the `authelia` bind user are seeded automatically by
   `lldap-bootstrap` on boot. The only manual step is creating a *human* login
   account for portal testing: browse `https://ldap.internal` from the
   management zone (admin login = `lldap-admin-password`), create your user,
   and add it to the `admin` group.

**Validation:** discovery responds at
`https://authelia.internal.mutantmell.net/.well-known/openid-configuration`;
the `jwks_uri` it advertises serves keys; portal login at
`https://authelia.internal.mutantmell.net` succeeds with an lldap account.

**Post-deploy fix (2026-06-03):** the portal returned `400` on first deploy.
Cause: `services.nginx.recommendedProxySettings` (set host-wide) already emits
`Host` + `X-Forwarded-*`, and the portal/`ldap.internal` vhosts re-set `Host`
in `extraConfig`. nginx sent two `Host` headers; Authelia's fasthttp parser
rejects that (`too many Host headers` → 400). Keycloak's Undertow tolerated the
same duplicate, which is why it never surfaced before. Fix: drop the redundant
`proxy_set_header` blocks (commit "don't double set proxy headers"). **Carry
into Phase 2e:** the new `auth_request`-protected langport vhosts must rely on
`recommendedProxySettings` for `Host`/`X-Forwarded-*` and not re-set them.
(2b no longer applies — it became a removal, not an auth_request migration.)

### Phase 2: Migrate consumers one at a time

Migrate each consumer from Keycloak to Authelia, testing after each switch.
Order from lowest-risk to highest-risk:

#### 2a. Perses (tharbad) — lowest risk, monitoring only

Update `hosts/calvard/microvm/guests/tharbad/modules/perses.nix`:

- Change `issuer` URL from `https://auth.mutantmell.net/realms/homelab` to
  `https://authelia.internal.mutantmell.net`
- Change `slug_id` and `name` from `keycloak` to `authelia`
- Update `redirect_uri` callback path if needed
- Update client secret in sops

**Validation:** Log into Perses via OIDC, verify admin role assignment.

> ~~2b. deployd-api~~ and ~~2c. cc-sandbox~~ removed — both consumers retired in
> the deployd decommission (2026-06-02). Remaining consumers renumbered below.

#### 2b. oauth2-proxy on phantasma — removal, not migration

**Premise obsolete (verified against config 2026-06-03).** This phase
originally migrated phantasma's oauth2-proxy to Authelia `auth_request` to keep
protecting the **AdGuard Home web UI**. AdGuard Home is gone — the blocky
migration (`llm-notes/done/blocky-migration-plan.md`) replaced phantasma's DNS
stack with **Blocky + Unbound**. There is no `services.adguardhome` on the guest
anymore, and nothing listens on `127.0.0.1:3000`. The surviving `proxy.nix`
fronts a dead upstream: the oauth2-proxy guards a `/adguard/` location that
proxies to a port nothing binds. Blocky's only HTTP surface is its metrics/REST
API on `127.0.0.1:4000` (loopback-only) — not a user-facing UI and not
something to gate with auth.

So phantasma has no web UI to protect. **Delete the proxy stack rather than
convert it.** This also drops an oauth2-proxy instance outright (one fewer
`auth_request` integration to build and validate) instead of moving it.

Remove on `hosts/thebeyond/microvm/guests/phantasma/`:

- `modules/proxy.nix` **in its entirety** — `services.nginx`,
  `services.oauth2-proxy`, the `/adguard/` and `/oauth2/` locations, the
  `phantasma.internal` vhost, `security.acme`, and the firewall ports 80/443.
  Drop the module import from `default.nix`.
- The `oauth2-proxy-internal-keyfile` sops secret (`sops.nix`).
- The `/var/lib/acme` persistence entry, if it lived in `proxy.nix` and nothing
  else on the guest uses ACME.
- Fix the stale `microvm.mem` comment ("Adguard + Unbound are lightweight").

Then remove the now-dead consumer-side config:

- The `phantasma.internal.mutantmell.net` rule in messeldam's `authelia.nix`
  `access_control.rules` — it points at a host that serves nothing.

**Pre-removal checks — both resolved (2026-06-04), deletion is guest-local:**

- **phantasma → messeldam forward rule — none exists.** The only OIDC forward
  rule on the router is `langport → messeldam` (`router.nix:291-297`).
  Phantasma's oauth2-proxy pointed its issuer at the public `auth.mutantmell.net`
  (langport ingress), not a direct cross-zone path, so there is no
  phantasma→messeldam rule to remove. Deleting `proxy.nix` requires no router
  change; phantasma's remaining forward rules are all DNS-related.
- **Blocky metrics scraping — never traversed nginx.** Blocky's HTTP/metrics
  endpoint is `127.0.0.1:4000` (loopback-only, `dns.nix:39`). nginx only ever
  exposed `/adguard` and `/oauth2/`, never `/metrics`/`:4000`. Metrics are
  push-model anyway (phantasma's `fluent-bit-agent` + `node-exporter-client`
  ship to vmsingle). Removing nginx has zero metrics impact.

**Validation:** after redeploy, phantasma serves only DNS (53). Ports 80/443 are
closed, no nginx/oauth2-proxy units exist, and the homelab's `*.internal`
resolution is unaffected (Blocky + Unbound untouched).

#### 2c. step-ca OIDC provisioner (basel) — higher risk, SSH certs

Done as two coexistence sub-steps so rollback never needs a revert.

**Step i — add `authelia` alongside `keycloak`** (`step-ca.nix`):

- Add a second OIDC provisioner `name = "authelia"`, `clientID = "step-ca"`,
  `configurationEndpoint =
  https://authelia.internal.mutantmell.net/.well-known/openid-configuration`,
  **no client secret** (public client — see design correction in the
  phase-status header). Keep the existing `keycloak` provisioner untouched.
  Both share `listenAddress = 127.0.0.1:10000`; step-cli binds it transiently
  per login, so two provisioners on the same loopback port don't conflict.
- The corresponding Authelia client in `authelia.nix` is flipped to
  `public: true` + `require_pkce`/`pkce_challenge_method: S256`, and the
  `authelia-oidc-step-ca-secret-hash` sops secret is dropped.
- SSH template needs no change: `oidc.tpl` reads `.Token.groups`, which Authelia
  emits via the `groups` scope (same as Keycloak).
- `step-ca-oidc-retry` now waits on **both** discovery endpoints and restarts
  step-ca unless both provisioners init'd cleanly. It stays — see the Phase 3
  step 5 note.
- `modules/common/ssh-cert-client.nix` default provisioner **stays `keycloak`**
  in this step.

**Step i validation:** `step ssh login --provisioner authelia` completes and
issues a valid SSH cert with correct principals, while the default
`step ssh login` (still keycloak) keeps working. `https://basel.internal/provisioners`
shows both `keycloak` and `authelia` without a `state` (error) field after boot
settles. Rollback during this window is trivial: just don't pass
`--provisioner authelia` — no redeploy/revert needed.

**Step ii — remove keycloak provisioner** (after step i is verified):

- Delete the `keycloak` OIDC provisioner from `step-ca.nix`.
- Flip `modules/common/ssh-cert-client.nix` default `provisioner` to `authelia`.
- Simplify `step-ca-oidc-retry` back to a single provider (authelia only).

**Step ii validation:** default `step ssh login` (now authelia) issues a valid
cert; `/provisioners` no longer lists `keycloak`.

#### 2d. Jellyfin LDAP (oracion) — moderate risk, media service

Configure Jellyfin to authenticate against lldap via the official LDAP plugin.
This replaces Jellyfin's built-in user management with the shared lldap
directory, giving media users one set of credentials across all services.

> **Bind account already seeded (landed in Phase 1 follow-up).** The read-only
> `jellyfin` bind user (in `lldap_strict_readonly`) is created declaratively by
> `lldap-bootstrap` on messeldam, alongside `authelia` — see `modules/lldap.nix`
> (`ensure_readonly_user`). Its password is the `jellyfin-ldap-bind-password`
> sops secret on messeldam; the **same value must be present in oracion's sops**
> for the plugin to bind. No manual web-UI account creation is needed for the
> bind identity — only the human `media-users` accounts below.

Update `hosts/calvard/microvm/guests/oracion/`:

- Install the official `jellyfin-plugin-ldap` plugin
- Configure LDAP connection to messeldam:3890 (bind DN
  `uid=jellyfin,ou=people,dc=mutantmell,dc=net`, password from oracion sops)
- Map lldap `media-users` group to Jellyfin access
- Add firewall rule: oracion → messeldam TCP 3890
- Test with all client types (web, mobile, TV apps)

**Validation:** Log into Jellyfin web UI and a mobile/TV app using lldap
credentials. Verify group-based access (media-users group grants access).

Note: Existing Jellyfin-local users may need migration or recreation in
lldap. Plan for a brief transition where both auth methods are active.

#### 2e. oauth2-proxy on langport — highest risk, external-facing

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
2. Update all consumers from `https://authelia.internal.mutantmell.net` to
   `https://auth.mutantmell.net` (final issuer URL), and add a `mutantmell.net`
   session cookie domain alongside the `internal.mutantmell.net` one
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
   - ~~`step-ca-oidc-retry` service on basel~~ — **do NOT remove.** Re-examined
     in Phase 2c: this is not a JVM-speed workaround, it's structural to an
     ACME chicken-and-egg. step-ca fetches the OIDC discovery doc at provisioner
     init, but Authelia's discovery is served over TLS by nginx using a cert
     ACME-issued by *this same* step-ca — so on a cold boot step-ca must serve
     ACME (OIDC degraded) before Authelia can present a valid cert, before
     step-ca can complete OIDC discovery. The circular dependency survives the
     Keycloak→Authelia switch unchanged; the retry service was repointed at
     Authelia in 2c and should stay. (A cleaner fix would be a proper
     systemd ordering/health-gate, but that's out of scope for this migration.)
   - `RestartSec`/`StartLimitBurst` retry config on oauth2-proxy in langport
     (`hosts/calvard/microvm/guests/langport/proxy.nix`) — oauth2-proxy
     itself is also removed in step 6
   - (phantasma's oauth2-proxy and its retry config are already gone — removed
     wholesale in Phase 2b, since its only consumer, AdGuard Home, no longer
     exists.)
6. Remove oauth2-proxy entirely from langport (phantasma was handled in 2b):
   - `services.oauth2-proxy` config blocks
   - `oauth-2-proxy-keyfile` sops secret on langport
   - All `oauth2/` nginx location blocks (replaced by `auth_request` to
     Authelia in Phase 2e)
7. Update `lib/common/data/network.nix` comment:
   `messeldam = 6; # Authelia OIDC (calvard)`
8. Update documentation and plan references

### Phase 4: Post-migration cleanup

1. Update `llm-notes/done/keycloak-oauth-oidc-plan.md` status to note
   replacement by Authelia
2. ~~Update `feature-roadmap-analysis.md` Step 4 (Keycloak OIDC)~~ — n/a,
   roadmap doc deleted (superseded by the plans/wip/done lifecycle)
3. ~~Update deployd auth references~~ — n/a, deployd retired (superseded by k8s; plan doc deleted)
4. Update `llm-notes/plans/headscale-integration-plan.md` Keycloak references
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

- lldap admin password
- lldap Authelia bind password (read-only service account)
- lldap Jellyfin bind password (read-only service account)
- Authelia JWT secret (signs session tokens)
- Authelia storage encryption key (encrypts SQLite data at rest)
- Authelia OIDC HMAC secret
- Authelia OIDC private key (RSA or ECDSA, for signing OIDC tokens)
- Per-client secrets (hashed, embedded in config — or via sops templates)

New sops secret on oracion:

- Jellyfin LDAP bind password (for querying lldap)

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

The headscale integration plan (`llm-notes/plans/headscale-integration-plan.md`)
references Keycloak throughout — OIDC client registration, cross-zone firewall
rules to Keycloak, architecture diagrams. All Keycloak references should be
updated to Authelia. The OIDC flows are identical (authorization code grant),
so this is a terminology update, not an architectural change.

Note: the friend-access report recommends pre-authkeys for friend enrollment
(no OIDC for friends), so the headscale OIDC integration only affects _admin_
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
Phase 0 ──── N/A (cc-sandbox retired in the deployd decommission)
              │
Phase 1 ──── Deploy lldap + Authelia on messeldam alongside Keycloak
              │
Phase 2a ─── Perses → Authelia
Phase 2b ─── Remove phantasma oauth2-proxy/nginx (AdGuard Home retired; nothing to protect)
Phase 2c ─── step-ca OIDC → Authelia
Phase 2d ─── Jellyfin → lldap (official LDAP plugin)
Phase 2e ─── langport oauth2-proxy → Authelia auth_request
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

Phases 2a–2e are sequential (one consumer at a time, validate between each).
Follow-ups F1–F5 are independent of each other and can be done in any order.
