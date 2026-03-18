# Keycloak OAuth2 / OIDC Integration Plan

> **Status:** Planning. This plan describes the target architecture, not the current
> deployment. Service placement reflects the intended state after the
> [vMGMT/vINFRA split](./secure-mgmt-vlan-plan.md) and related refactors.

## Goals

1. **OAuth2 provider for step-ca** — Keycloak issues OIDC tokens that step-ca uses to
   sign short-lived SSH certificates (covered by [ssh-certificates-sso-plan](./ssh-certificates-sso-plan.md),
   listed here for completeness).
2. **Web traffic gating for vDMZ** — oauth2-proxy on ordis gates all inbound web traffic
   arriving via WireGuard from a cloud host. Users must authenticate through Keycloak
   before reaching backend services.
3. **OIDC integration for services** — Services that support OIDC natively (e.g. Grafana,
   Gitea, HomeAssistant) authenticate directly against Keycloak without going through
   oauth2-proxy.
4. **Dynamic user accounts** — Keycloak is the central user directory. Accounts are managed
   at runtime via the admin console or API, not in NixOS configuration (no credentials in
   a public repo).

## Target Service Placement

| Component              | Host              | Network | External Name         | Notes                                                      |
| ---------------------- | ----------------- | ------- | --------------------- | ---------------------------------------------------------- |
| Keycloak               | dedicated microvm | vINFRA  | `auth.mutantmell.net` | OIDC provider, user directory                              |
| step-ca                | dedicated microvm | vINFRA  | — (internal only)     | SSH CA + ACME CA, isolated key material                    |
| oauth2-proxy + nginx   | ordis             | vDMZ    | `mutantmell.net`      | Web traffic gating for externally-reachable services       |
| oauth2-proxy + nginx   | phantasma         | vINFRA  | — (internal only)     | Auth gating for strictly internal services (Adguard, etc.) |
| SSH bastion            | dedicated microvm | vDMZ    | — (SSH only)          | SSH-only jump host, reachable from wg-ba                   |
| nginx (Keycloak proxy) | ordis             | vDMZ    | `auth.mutantmell.net` | Proxies Keycloak for external users (separate vhost)       |
| nginx (Keycloak local) | Keycloak microvm  | vINFRA  | —                     | Local reverse proxy for Keycloak                           |
| nginx (ACME endpoint)  | step-ca microvm   | vINFRA  | —                     | TLS termination + proxy to step-ca :9443                   |

### What exists in Keycloak today

- An `external` realm with an `oauth2-proxy` client (referenced by ordis's config)
- Keycloak accessible at `https://gridr.local/auth`
- OIDC issuer URL: `https://gridr.local/auth/realms/external`

### What this plan addresses

- DNS and naming strategy (split-horizon DNS with `mutantmell.net` canonical names)
- Keycloak and step-ca placement on vINFRA (dedicated microvms)
- OIDC provisioner on step-ca for SSH certificate issuance
- Declarative realm/client configuration (currently manual)
- Group/role structure for access control
- Cross-VLAN firewall rules (vDMZ → Keycloak, vDMZ → step-ca, wg-ba per-service rules)
- External access architecture (cloud host → WireGuard → oauth2-proxy → Keycloak)
- SSH bastion microvm on vDMZ (split from ordis for hardening)
- ACME endpoint on step-ca microvm, reachable from vDMZ via dedicated firewall rule
- Microvm resource sizing

---

## Hosting Decision

### Keycloak: dedicated microvm on vINFRA

Keycloak is infrastructure. It's the identity provider for the entire network — every
service that authenticates users depends on it. This puts it in the same category as DNS
(phantasma), NTP (thebeyond), and step-ca: foundational services that belong on the
management plane.

| Consideration             | vHOME                                | vINFRA                                                   |
| ------------------------- | ------------------------------------ | -------------------------------------------------------- |
| Role classification       | User devices, media, home automation | Infrastructure services (DNS, NTP, CA)                   |
| step-ca → Keycloak (OIDC) | Cross-zone (management → trusted)    | Intra-zone (management → management)                     |
| phantasma → Keycloak      | Cross-zone (management → trusted)    | Intra-zone (management → management)                     |
| User browsers → Keycloak  | Intra-zone (trusted → trusted)       | Cross-zone (trusted → management, allowed by `accessTo`) |
| Can be reached from vDMZ  | Needs explicit rule                  | Needs explicit rule                                      |
| Internet access           | Unfiltered                           | Filtered (HTTP/HTTPS/DNS/NTP — sufficient for Keycloak)  |

Both zones require an explicit firewall rule for vDMZ access, so that's a wash. The
deciding factor is that vINFRA consolidates auth infrastructure: step-ca → Keycloak and
phantasma → Keycloak become intra-zone traffic. The OIDC provisioner connection (step-ca →
Keycloak for token validation) is the most security-sensitive path, and keeping it within
the management zone is cleaner than routing it across zones.

The "user-facing" argument for vHOME doesn't hold up. DNS is equally user-facing — every
device on every VLAN queries phantasma — yet it belongs on vINFRA. The question is what role
the service plays, not who talks to it.

### step-ca: dedicated microvm on vINFRA

step-ca moves to its own microvm on vINFRA, as specified in the
[SSH certificates plan](./ssh-certificates-sso-plan.md). A dedicated microvm provides
isolation for CA key material. step-ca and Keycloak are on separate microvms despite being
on the same zone — Keycloak runs a JVM + PostgreSQL with significant attack surface, while
step-ca is a minimal Go binary holding the CA root key.

### ACME endpoint on the step-ca microvm

step-ca already serves ACME over TLS on `:9443`. The step-ca microvm runs its own nginx
to provide a clean `:443` ACME endpoint:

```
vDMZ host → step-ca microvm (vINFRA, :443/acme) → step-ca (localhost, :9443/acme)
```

This keeps ACME completely decoupled from Keycloak. Each microvm has a single
responsibility: Keycloak handles identity, step-ca handles certificates. A compromise
of either doesn't affect the other's traffic path. Since cloud-hypervisor microvms are
lightweight, the extra microvm nginx is negligible cost for meaningful isolation.

### Microvm sizing

| Microvm     | vCPU | RAM    | Persistent Storage         | Services                       |
| ----------- | ---- | ------ | -------------------------- | ------------------------------ |
| Keycloak    | 2    | 2048MB | ~100GB (PostgreSQL)        | Keycloak, PostgreSQL, nginx    |
| step-ca     | 1    | 512MB  | Small (badger DB, CA keys) | step-ca, nginx (ACME endpoint) |
| SSH bastion | 1    | 256MB  | None (stateless)           | sshd only                      |

> **Note on bastion hosting:** The SSH bastion will likely need to be a VM hosted by
> Incus rather than a cloud-hypervisor microvm, since it lives on vDMZ (hosted by
> erebonia, which runs Incus). We currently only run Incus containers — running an
> Incus VM is a new capability that needs to be figured out (VM image configuration,
> NixOS integration, networking with Incus VMs vs containers, etc.). This is a
> prerequisite for Phase 3.

step-ca's persistent storage holds the CA root key material and the badger database.
This data is critical — loss means re-provisioning all certificates. Back up alongside
other infrastructure secrets.

### Architecture diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ vINFRA (management zone)                                        │
│                                                                 │
│   Keycloak microvm  (auth.mutantmell.net → internal DNS)        │
│     ├── Keycloak (OIDC provider, hostname=auth.mutantmell.net)  │
│     └── nginx (/auth → Keycloak :9080)                          │
│                                                                 │
│   step-ca microvm                                               │
│     ├── step-ca (OIDC provisioner validates against Keycloak)   │
│     └── nginx (/acme → step-ca :9443)                           │
│                                                                 │
│   phantasma ────→ Keycloak microvm (OIDC, intra-zone)             │
│     ├── Unbound (split-horizon: mutantmell.net, *.internal,     │
│     │   *.internal.mutantmell.net)                              │
│     ├── oauth2-proxy (internal, --allowed-groups=admins)        │
│     ├── nginx (auth_request → local oauth2-proxy)               │
│     └── nginx (/adguard → Adguard Home :3000)                   │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ vHOME (trusted zone)                                            │
│   User browsers → auth.mutantmell.net (DNS → Keycloak, direct) │
│   User browsers → mutantmell.net (DNS → ordis, direct)          │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ vDMZ (untrusted zone)                    [explicit FW rules]    │
│   ordis ────→ Keycloak microvm (OIDC)                           │
│     ├── oauth2-proxy (gates internet-facing traffic)            │
│     ├── nginx vhost: auth.mutantmell.net (Keycloak proxy,       │
│     │   external users only)                                    │
│     └── nginx vhost: mutantmell.net (services + oauth2-proxy)   │
│   ordis, heimdallr, ardent ────→ step-ca microvm (ACME)           │
│                                                                 │
│   SSH bastion microvm (sshd only, no other services)            │
│     └── reachable from wg-ba:22 via port forward                │
│                                                                 │
├─── wg-ba (isolated) ────────────────────────────────────────────┤
│   Cloud host → SSH:22 → bastion microvm (vDMZ)                  │
│   Cloud host → HTTPS:443 → ordis (vDMZ)                         │
│     ├── Host: auth.mutantmell.net → ordis → Keycloak            │
│     └── Host: mutantmell.net → ordis → backend services         │
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

| Client ID               | Type         | Grant Types        | Purpose                                  | Redirect URIs                                                  |
| ----------------------- | ------------ | ------------------ | ---------------------------------------- | -------------------------------------------------------------- |
| `oauth2-proxy`          | Confidential | Authorization Code | External web traffic gating (ordis)      | `https://mutantmell.net/oauth2/callback`                       |
| `oauth2-proxy-internal` | Confidential | Authorization Code | Internal service auth gating (phantasma) | `https://phantasma.internal.mutantmell.net/oauth2/callback`    |
| `step-ca`               | Confidential | Authorization Code | SSH certificate issuance (interactive)   | `http://127.0.0.1:*` (localhost callback for `step ssh login`) |
| `cicd-deploy`           | Confidential | Client Credentials | CI/CD machine-to-machine auth            | N/A (no browser redirect)                                      |

Note that `oauth2-proxy` needs only a single redirect URI — split-horizon DNS means
internal and external users both access ordis via `mutantmell.net`.

The internal `oauth2-proxy-internal` client is separate from the external `oauth2-proxy`
client so that each can have independent redirect URIs, group restrictions, and audit
trails. The internal proxy should use `--allowed-groups=admins` since only administrators
should access infrastructure UIs like Adguard Home.

Additional clients added per-service as OIDC integrations are enabled (see
[OIDC Integrations](#oidc-integrations) below).

**Client secrets** are stored in sops-nix on the hosts that need them:

- `oauth2-proxy` secret → ordis's sops secrets
- `oauth2-proxy-internal` secret → phantasma's sops secrets
- `step-ca` OIDC provisioner secret → step-ca microvm's sops secrets
- `cicd-deploy` secret → CI/CD server's environment (encrypted at rest)

### Groups and roles

Groups control access across services. Keycloak groups can be mapped to:

- oauth2-proxy's `--allowed-groups` (restrict which users can access web services)
- step-ca SSH certificate principals (map groups → SSH principals)
- Per-service OIDC claims (service-specific role mapping)

| Group         | Purpose                     | SSH Principal | Web Access          |
| ------------- | --------------------------- | ------------- | ------------------- |
| `admins`      | Full access to everything   | `admin`       | All services        |
| `media-users` | Jellyfin and media services | —             | Media services only |
| `deploy`      | CI/CD service accounts      | `deploy`      | —                   |

Group membership is managed dynamically via the Keycloak admin console. The group
_structure_ (names, role mappings, protocol mappers) can be managed declaratively
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

| Source                | Destination               | Port | Purpose                                      | Status                                                |
| --------------------- | ------------------------- | ---- | -------------------------------------------- | ----------------------------------------------------- |
| ordis (vDMZ)          | Keycloak microvm (vINFRA) | 443  | oauth2-proxy → Keycloak OIDC                 | **Needs explicit rule**                               |
| vDMZ ACME clients     | step-ca microvm (vINFRA)  | 443  | ACME cert issuance                           | **Needs explicit rule**                               |
| wg-ba peers           | bastion microvm (vDMZ)    | 22   | SSH from cloud host                          | **Needs explicit rule** (replaces ordis port forward) |
| wg-ba peers           | ordis (vDMZ)              | 443  | External web traffic                         | Already in extraForwardRules                          |
| step-ca (vINFRA)      | Keycloak microvm (vINFRA) | 443  | OIDC provisioner → Keycloak token validation | Intra-zone (management → management)                  |
| phantasma (vINFRA)    | Keycloak microvm (vINFRA) | 443  | Internal oauth2-proxy → Keycloak OIDC        | Intra-zone (management → management)                  |
| User browsers (vHOME) | Keycloak microvm (vINFRA) | 443  | OAuth login page                             | Allowed (trusted → management)                        |

The first three rows require explicit firewall rules. The OIDC and ACME rules are
separate with distinct destination IPs (compromise of one doesn't grant access to the
other). The wg-ba → bastion rule replaces the current wg-ba → ordis SSH port forward,
moving SSH to a dedicated microvm so ordis can drop its SSH daemon entirely. All
intra-zone paths work without rules. User browsers on vHOME reach Keycloak via the
existing `trusted` → `management` `accessTo` rule.

Note that phantasma's auth_request no longer crosses to ordis (vDMZ). With a local
oauth2-proxy on phantasma, the auth flow is entirely intra-zone (phantasma → Keycloak,
both on vINFRA). This eliminates the previous management → untrusted dependency for
internal service authentication.

**Implementation** — add to `extraForwardRules` on thebeyond:

```nix
firewall.extraForwardRules = [
  # Existing rule: vDMZ return traffic to wg-ba
  { iifname = "vDMZ.br0"; oifname = "wg-ba"; verdict = "accept"; }

  # wg-ba → ordis (HTTPS only) and bastion (SSH only)
  { iifname = "wg-ba"; ip.daddr = "10.0.100.40"; tcp.dport = 443; verdict = "accept";
    comment = "wg-ba -> ordis (HTTPS)"; }
  { iifname = "wg-ba"; ip.daddr = "<bastion-microvm-ip>"; tcp.dport = 22; verdict = "accept";
    comment = "wg-ba -> bastion (SSH)"; }

  # ordis needs Keycloak for OIDC token exchange
  {
    iifname = "vDMZ.br0";
    oifname = "vINFRA.br0";
    ip.saddr = "10.0.100.40";           # ordis only
    ip.daddr = "<keycloak-microvm-ip>";
    tcp.dport = 443;
    verdict = "accept";
    comment = "ordis -> Keycloak microvm (OIDC)";
  }

  # vDMZ hosts need step-ca for ACME certificate issuance
  {
    iifname = "vDMZ.br0";
    oifname = "vINFRA.br0";
    ip.daddr = "<step-ca-microvm-ip>";
    tcp.dport = 443;
    verdict = "accept";
    comment = "vDMZ -> step-ca microvm (ACME)";
  }
];

# Remove the old SSH port forward to ordis — replaced by bastion
# portForwards = [
#   { proto = "tcp"; sourcePort = 22; destination = "10.0.100.40:22";
#     sourceInterface = "wg-ba"; }
# ];
```

The wg-ba rules are now explicit per-service: HTTPS to ordis, SSH to the bastion. The
old blanket `{ iifname = "wg-ba"; ip.daddr = "10.0.100.40"; verdict = "accept"; }` rule
(which allowed all ports to ordis) and the SSH port forward are both removed. This means
wg-ba can only reach ordis on :443 and the bastion on :22 — nothing else.

**Note on phantasma:** phantasma now runs its own oauth2-proxy instance for internal
service auth (see [Internal vs External oauth2-proxy](#internal-vs-external-oauth2-proxy)).
phantasma's auth flow is entirely intra-zone (phantasma → Keycloak, both on vINFRA) —
no cross-zone dependency on ordis.

### ACME endpoint on the step-ca microvm

The step-ca microvm runs nginx to provide a clean `:443` ACME endpoint, proxying to
the local step-ca on `:9443`:

```nix
# On the step-ca microvm
services.nginx = {
  enable = true;
  recommendedTlsSettings = true;
  recommendedProxySettings = true;

  virtualHosts."${config.networking.hostName}.internal.mutantmell.net" = {
    forceSSL = true;
    enableACME = true;  # Bootstrap via step-ca's own ACME (localhost)

    locations."/acme" = {
      proxyPass = "https://127.0.0.1:9443/acme";
      extraConfig = ''
        proxy_ssl_certificate /etc/nginx/nginx.cert;
        proxy_ssl_certificate_key /etc/nginx/nginx.key;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_ciphers HIGH:!aNULL:!MD5;
      '';
    };
  };
};
```

All ACME clients use `https://<step-ca-host>.internal.mutantmell.net/acme/acme/directory`
(or `https://<step-ca-host>.internal/acme/acme/directory` for short) as their ACME server
URL. This is a direct path — no intermediate proxy through Keycloak.

---

## DNS and Naming Strategy

### Problem: dual-hostname split logic and `.local` fragility

Services accessible from both the LAN and the internet need a consistent identity. If
internal users use one set of hostnames and external users use another, every component
that bridges both audiences needs conditional configuration: oauth2-proxy needs separate
`login-url` (external hostname) and `redeem-url` (internal hostname), Keycloak needs
dual-hostname mode (`hostname` + `hostname-backchannel-dynamic`), cookie domains vary by
access path, and OIDC issuer validation requires careful matching between what Keycloak
stamps in tokens and what oauth2-proxy expects. A misconfiguration in any single
component causes opaque authentication failures.

Additionally, `.local` is reserved by RFC 6762 for mDNS (multicast DNS / Bonjour /
Avahi). Using it with unicast DNS (Unbound) creates a protocol conflict —
systemd-resolved may route `.local` queries to mDNS instead of the configured DNS
server, and macOS always prefers mDNS for `.local`. This works today by accident of
client configuration but is fragile.

### Solution: split-horizon DNS with `mutantmell.net` naming hierarchy

Use `mutantmell.net` as the root of all DNS naming:

- **Externally-accessible services** use `mutantmell.net` subdomains directly
  (e.g., `auth.mutantmell.net`). Internal DNS resolves these to internal IPs via
  split-horizon; external DNS resolves them to the cloud host.
- **Internal-only hosts** use `internal.mutantmell.net` subdomains as their canonical
  name (e.g., `phantasma.internal.mutantmell.net`), with `.internal` as a short
  convenience alias (e.g., `phantasma.internal`). Both resolve to the same IP. The
  `.internal` TLD was reserved by ICANN (2024) for private network use — no collision
  risk, no mDNS conflict.

### Naming scheme

| Name                        | Zone type     | Internal DNS target       | External DNS target           | Purpose                           |
| --------------------------- | ------------- | ------------------------- | ----------------------------- | --------------------------------- |
| `auth.mutantmell.net`       | `transparent` | Keycloak microvm (vINFRA) | Cloud host → ordis → Keycloak | OIDC provider                     |
| `mutantmell.net`            | `transparent` | ordis (vDMZ)              | Cloud host → ordis            | Externally-reachable services     |
| `*.internal.mutantmell.net` | `static`      | Per host                  | N/A (NXDOMAIN externally)     | Internal-only hosts (canonical)   |
| `*.internal`                | `static`      | Per host (same IPs)       | N/A                           | Internal-only hosts (short alias) |

> **Note:** `mutantmell.net` is a placeholder — the specific domain/subdomain scheme for
> externally-reachable services (e.g., `jellyfin.mutantmell.net` vs `mutantmell.net/jellyfin`)
> can be decided per-service as they're deployed. The critical decision is using
> `auth.mutantmell.net` for Keycloak, since the OIDC issuer URL must be stable and
> consistent everywhere. `mutantmell.net` pointing to ordis is shown as the simplest
> starting point.

The `static` zones ensure internal names never leak to the internet: unknown names
return NXDOMAIN locally without forwarding to upstream resolvers. The `transparent`
zone for `mutantmell.net` answers overridden names locally but forwards other
subdomains upstream normally.

### Why this eliminates split configuration

With split-horizon DNS, all components use the same canonical hostname:

- **oauth2-proxy** (ordis and phantasma): `oidc-issuer-url`, `login-url`, `redeem-url`,
  and `oidc-jwks-url` all use `auth.mutantmell.net`. No split. In fact, explicit URL
  overrides become unnecessary — `oidc-issuer-url` alone suffices and oauth2-proxy
  discovers the rest from the OIDC discovery document.
- **Keycloak**: `hostname = "auth.mutantmell.net"` with `hostname-strict = true`
  (default). No `hostname-backchannel-dynamic` needed. All tokens have the same issuer.
- **Cookie domain**: `mutantmell.net` for external services, `.internal` (or
  `.internal.mutantmell.net`) for internal services. No ambiguity.
- **OIDC issuer**: always `https://auth.mutantmell.net/auth/realms/homelab`, regardless
  of whether the request came from the LAN or the internet.

Internal clients (oauth2-proxy, step-ca) resolve the hostname to the internal IP and
connect directly. External browsers resolve it to the cloud host. Same URLs, different
network paths.

### Key security benefit: internal auth bypasses vDMZ

With `auth.mutantmell.net` resolving to the Keycloak microvm directly for internal users:

```
Internal browser → auth.mutantmell.net → (DNS: Keycloak microvm on vINFRA)
```

Internal OAuth login pages are served directly by Keycloak — ordis (vDMZ) is not in the
path. The internal authentication flow never traverses the untrusted zone. Only external
users' auth traffic goes through ordis's Keycloak proxy.

Compare with the path-based alternative (`mutantmell.net/auth`), where internal DNS
would point `mutantmell.net` at ordis, forcing internal auth through vDMZ — the wrong
trust direction.

### Unbound configuration changes

Replace the existing `.local` zone with three zones:

```nix
# In phantasma's dns.nix — replace the existing local-zone/local-data config
local-zone = [
  # External domain overrides (split-horizon): answers local-data, forwards the rest
  ''"mutantmell.net." transparent''

  # Internal hosts (canonical): authoritative, never forwards upstream
  ''"internal.mutantmell.net." static''

  # Internal hosts (short alias): authoritative, never forwards upstream
  ''"internal." static''
];

local-data = [
  # --- Split-horizon overrides for externally-accessible services ---

  # Auth (Keycloak) — internal clients connect directly to Keycloak microvm
  ''"auth.mutantmell.net. A <keycloak-microvm-ip>"''

  # External services — internal clients connect to ordis
  ''"mutantmell.net. A 10.0.100.40"''

  # --- Internal hosts (canonical + short alias, same IPs) ---

  # Router
  ''"thebeyond.internal.mutantmell.net. A 10.0.10.1"''
  ''"thebeyond.internal.                 A 10.0.10.1"''

  # DNS (this microvm)
  ''"phantasma.internal.mutantmell.net.    A 10.0.10.2"''
  ''"phantasma.internal.                   A 10.0.10.2"''

  # ... same dual-entry pattern for every internal host ...
];
```

The `static` zones are authoritative: unknown names return NXDOMAIN locally without
ever forwarding to upstream resolvers. No internal DNS queries leak to the internet.
The `transparent` zone for `mutantmell.net` answers overridden names locally but
forwards other subdomains upstream normally.

> **Migration note:** The existing `.local` zone and all its entries are removed
> entirely. All internal hostnames move to `*.internal.mutantmell.net` (canonical) +
> `*.internal` (short alias). This is a coordinated change — every host's
> `networking.hostName`, ACME config, nginx `server_name`, and any hardcoded hostname
> references must be updated simultaneously. Phase 3 handles this migration.

### step-CA certificate policy changes

Replace the existing `*.local`-only policy to allow the full naming hierarchy:

```nix
policy = let
  allowInternal = {
    allow = {
      dns = [
        "*.internal.mutantmell.net"   # Canonical internal names
        "*.internal"                   # Short aliases
        "*.mutantmell.net"             # External-facing names (auth.mutantmell.net, etc.)
        "mutantmell.net"               # Bare domain
      ];
      ip = [ "10.0.0.0/16" "10.1.0.0/16" "10.97.0.0/16" ];
    };
  };
in {
  x509 = allowInternal;
  ssh.host = allowInternal;
};
```

### Dual-SAN certificates

Internal hosts request certificates with both the canonical name and the short alias
as Subject Alternative Names (SANs). This way TLS works regardless of which name is
used to access the host:

```
# Example: phantasma requests a cert via ACME with two SANs:
#   - phantasma.internal.mutantmell.net  (canonical)
#   - phantasma.internal                 (short alias)
```

step-CA's ACME provisioner supports multi-SAN certificate requests natively. The NixOS
ACME module can request additional SANs via `extraDomainNames`:

```nix
# Example for phantasma's nginx ACME config
security.acme.certs."phantasma.internal.mutantmell.net" = {
  extraDomainNames = [ "phantasma.internal" ];
};
```

Externally-accessible hosts (ordis, Keycloak microvm) similarly include both their
internal and external names as SANs where appropriate:

```nix
# Keycloak microvm: cert covers both external OIDC name and internal admin name
security.acme.certs."auth.mutantmell.net" = {
  extraDomainNames = [ "<keycloak-host>.internal.mutantmell.net" "<keycloak-host>.internal" ];
};
```

The same policy narrowing concerns from S9 apply — a compromised vDMZ host could
request a cert for `auth.mutantmell.net`. See S9 for mitigations.

### TLS certificate strategy

| Access path                    | Certificate issuer | Certificate SANs                                                                               | Why it's trusted                                                |
| ------------------------------ | ------------------ | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| LAN → Keycloak (OIDC)          | step-CA            | `auth.mutantmell.net` + `<keycloak-host>.internal.mutantmell.net` + `<keycloak-host>.internal` | Internal hosts have step-CA root in `security.pki.certificates` |
| LAN → ordis (services)         | step-CA            | `mutantmell.net` + `ordis.internal.mutantmell.net` + `ordis.internal`                          | Same                                                            |
| LAN → phantasma (admin)        | step-CA            | `phantasma.internal.mutantmell.net` + `phantasma.internal`                                     | Same                                                            |
| Internet → cloud host          | Let's Encrypt      | `*.mutantmell.net` (or per-subdomain)                                                          | Browsers trust LE root                                          |
| Cloud host → ordis (WireGuard) | step-CA            | (same as LAN → ordis)                                                                          | Cloud host imports step-CA root                                 |

Internal hosts already trust the step-CA root (distributed via `security.pki.certificates`).
External users never see step-CA certs — the cloud host terminates their TLS with a
Let's Encrypt certificate and forwards through WireGuard to ordis. The cloud host needs
the step-CA root installed to verify ordis's certificate over the WireGuard-internal
HTTPS connection.

Dual-SAN certs mean both the canonical name (`phantasma.internal.mutantmell.net`) and
the short alias (`phantasma.internal`) are valid for TLS — no certificate warnings
regardless of which name is used.

### Internal-only services

Internal-only services use `*.internal.mutantmell.net` (canonical) and `*.internal`
(short alias). These names are never reachable from the internet:

| Service                 | Canonical name                            | Short alias                | Notes                                 |
| ----------------------- | ----------------------------------------- | -------------------------- | ------------------------------------- |
| AdGuard Home admin      | `phantasma.internal.mutantmell.net`       | `phantasma.internal`       | Strictly internal, infrastructure     |
| Keycloak admin console  | `<keycloak-host>.internal.mutantmell.net` | `<keycloak-host>.internal` | Never exposed externally (S5)         |
| step-CA ACME endpoint   | `<step-ca-host>.internal.mutantmell.net`  | `<step-ca-host>.internal`  | Internal cert issuance only           |
| Future vINFRA admin UIs | `*.internal.mutantmell.net`               | `*.internal`               | Infrastructure services stay internal |

The Keycloak microvm's nginx serves two vhosts: the internal name
(`<keycloak-host>.internal.mutantmell.net`) for admin console access, and
`auth.mutantmell.net` for OIDC operations (the name that appears in tokens and
browser redirects).

---

## External Access Architecture

The intended external access path is:

```
External user → Cloud host (public IP) → WireGuard (wg-ba) → ordis (vDMZ) → backend services
```

### The Keycloak reachability problem

In a standard OAuth2 flow, the user's **browser** is redirected to Keycloak's login page.
oauth2-proxy tells the browser "go to `https://auth.mutantmell.net/auth/realms/homelab/...`
to log in." Internal browsers resolve `auth.mutantmell.net` to the Keycloak microvm
directly (via split-horizon DNS) — this path works without any proxying.

External browsers resolve `auth.mutantmell.net` to the cloud host's public IP. The cloud
host can only reach vDMZ through WireGuard, not the Keycloak microvm on vINFRA directly.
So external auth traffic needs to be proxied through ordis.

There are two sub-flows that need Keycloak:

1. **Browser redirect** — user's browser loads Keycloak login page (needs browser → Keycloak)
2. **Token exchange** — oauth2-proxy exchanges auth code for tokens (needs ordis → Keycloak)

For internal users, both flows work directly (split-horizon DNS resolves to Keycloak
microvm, intra-zone or cross-zone with existing `accessTo` rules). For external users,
flow (2) works via the explicit firewall rule (ordis → Keycloak). Flow (1) requires
ordis to proxy `auth.mutantmell.net` to the Keycloak microvm.

### Solution: ordis proxies `auth.mutantmell.net` for external users

ordis gets a dedicated `auth.mutantmell.net` virtual host that reverse-proxies to the
Keycloak microvm. This vhost only handles external auth traffic — internal users never
hit it (their DNS resolves to Keycloak directly).

```
External browser                               Internal network
      │                                              │
      ├── GET auth.mutantmell.net/auth/... ──→ ordis ──→ Keycloak microvm (vINFRA)
      ├── POST mutantmell.net/oauth2/callback ──→ ordis (oauth2-proxy)
      └── GET mutantmell.net/ ─────────────────→ ordis ──→ backend service

Internal browser
      │
      ├── GET auth.mutantmell.net/auth/... ──→ Keycloak microvm directly (DNS)
      ├── POST mutantmell.net/oauth2/callback ──→ ordis (oauth2-proxy)
      └── GET mutantmell.net/ ─────────────────→ ordis ──→ backend service
```

**ordis nginx: `auth.mutantmell.net` virtual host (Keycloak proxy for external users):**

```nix
virtualHosts."auth.mutantmell.net" = {
  forceSSL = true;
  enableACME = true;  # step-CA cert for auth.mutantmell.net

  # Block admin console — external users must not reach it (S5)
  locations."/auth/admin" = {
    return = "403";
  };
  locations."/auth/realms/master" = {
    return = "403";
  };

  # Proxy OIDC endpoints to Keycloak
  locations."/auth" = {
    proxyPass = "https://<keycloak-host>.internal/auth";
    extraConfig = ''
      proxy_set_header Host $host;  # Passes auth.mutantmell.net to Keycloak
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $remote_addr;  # Overwrite, don't append (S13)
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_buffer_size 128k;
      proxy_buffers 4 256k;
      proxy_busy_buffers_size 256k;
    '';
  };
};
```

This is a simple, single-purpose vhost: proxy Keycloak for external users, block admin
paths. No split logic — the `Host` header is always `auth.mutantmell.net`, which matches
Keycloak's `hostname` setting.

**ordis nginx: `mutantmell.net` virtual host (services + oauth2-proxy):**

The service vhost is separate from the auth proxy vhost. It runs oauth2-proxy and
proxies to backend services:

```nix
virtualHosts."mutantmell.net" = {
  forceSSL = true;
  enableACME = true;  # step-CA cert for mutantmell.net

  locations."/" = {
    proxyPass = "https://heimdallr.internal";  # Jellyfin, etc.
    extraConfig = ''
      auth_request /oauth2/auth;
      # ... proxy headers, websocket support, etc.
    '';
  };

  locations."/oauth2/" = {
    proxyPass = "http://127.0.0.1:4180";
    # ... oauth2-proxy proxy config
  };
};
```

**oauth2-proxy configuration (simplified by split-horizon DNS):**

With split-horizon DNS, all URLs use the canonical `auth.mutantmell.net` hostname.
No split between "browser-facing" and "server-side" URLs — they're all the same:

```nix
services.oauth2-proxy = {
  enable = true;
  provider = "oidc";
  clientID = "oauth2-proxy";
  keyFile = config.sops.secrets."oauth2-proxy-keyfile".path;
  extraConfig = {
    "provider-display-name" = "Keycloak";
    "oidc-issuer-url" = "https://auth.mutantmell.net/auth/realms/homelab";
    # No explicit login-url, redeem-url, or oidc-jwks-url needed —
    # oauth2-proxy discovers them from the OIDC discovery document.
    # This works because auth.mutantmell.net resolves correctly for
    # both the browser (login redirect) and the server (token exchange).
  };
  cookie = {
    secure = true;                 # S1
    refresh = "1m";
    expire = "30m";
    domain = ".mutantmell.net";    # Scoped to the external domain
  };
  redirectURL = "https://mutantmell.net/oauth2/callback";
  email.domains = [ "*" ];         # Controlled by group restriction (see S10)
};
```

Compare with the pre-split-horizon version, which needed four separate URL overrides
with a mix of internal and external hostnames. The split-horizon approach reduces this
to a single `oidc-issuer-url`.

**Keycloak hostname configuration:**

Keycloak uses a single fixed hostname. No dual-mode configuration needed:

```nix
services.keycloak.settings = {
  # ... existing settings ...
  hostname = "https://auth.mutantmell.net";   # Fixed issuer URL for all tokens
  # hostname-strict = true;           # Default — leave it
  # hostname-backchannel-dynamic is NOT set. All clients (oauth2-proxy,
  # step-ca, browsers) use auth.mutantmell.net. Internal clients resolve
  # it to the Keycloak microvm directly via split-horizon DNS.

  # Admin console restricted to internal hostname only. Prevents the admin
  # console UI from being served via auth.mutantmell.net — even if ordis's
  # nginx /auth/admin/ block (S5) is bypassed, Keycloak itself refuses to
  # serve the admin console on the public hostname.
  # Note: hostname must be a full URL (not just hostname) when hostname-admin is set.
  hostname-admin = "https://<keycloak-host>.internal.mutantmell.net";
};
```

**Admin console access control (defense in depth):**

The `hostname-admin` setting ensures the admin console UI is only accessible via the
internal hostname (reachable from vINFRA and vHOME, not from vDMZ through the ordis →
Keycloak firewall rule). This is the second line of defense behind S5's nginx path
blocks on ordis — critically, `hostname-admin` survives a ordis compromise because
it's enforced by Keycloak itself on vINFRA.

**Caveat:** `hostname-admin` only restricts the admin console UI. The admin REST API
endpoints (`/auth/admin/realms/...`) remain accessible via the public hostname, but
they require valid admin credentials + MFA, and Keycloak's brute force protection
rate-limits attempts. The S5 nginx blocks should still be kept as the first layer.

Tokens always have issuer `https://auth.mutantmell.net/auth/realms/homelab` regardless
of access path. All oauth2-proxy instances and step-ca use the same issuer URL.
See [Security Considerations S4](#security-considerations).

### Cloud host configuration (future work)

The cloud host is not yet deployed. When it is, it needs:

1. **nginx/caddy** — TLS termination with a Let's Encrypt certificate for
   `*.mutantmell.net` (wildcard via DNS-01 challenge) or per-subdomain certs
2. **WireGuard client** — connects to thebeyond's wg-ba tunnel
3. **step-CA root certificate** — imported so the cloud host can verify ordis's
   step-CA-issued TLS cert over the WireGuard-internal HTTPS connection
4. **Reverse proxy rules** — forward all HTTPS traffic through WireGuard to ordis,
   routing by `Host` header:
   - `auth.mutantmell.net` → ordis (which proxies to Keycloak)
   - `mutantmell.net` → ordis (services)
   - Strip/overwrite `X-Forwarded-For` at this layer (S13)

The cloud host is intentionally minimal: a dumb pipe that terminates public TLS and
forwards to ordis. All authentication logic lives on ordis (oauth2-proxy) and the
Keycloak microvm (vINFRA). If the cloud host is compromised, the attacker gets
encrypted WireGuard traffic and an OAuth login page — no direct access to backend
services.

### Internal access (LAN users)

For users on vHOME or vINFRA, split-horizon DNS makes the external domain names work
transparently on the LAN:

- `auth.mutantmell.net` resolves to the Keycloak microvm — browser loads the login page
  directly from vINFRA (trusted → management is allowed by `accessTo`)
- `mutantmell.net` resolves to ordis — oauth2-proxy handles auth, then proxies to
  backend services
- The oauth2-proxy → Keycloak server-side flow (token exchange, JWKS) also uses
  `auth.mutantmell.net`, which resolves to Keycloak directly from ordis's perspective

No cloud host, no external routing, no split URLs. Internal users use the same domain
names as external users; only the DNS resolution and network path differ.

For strictly internal services (AdGuard Home, etc.): oauth2-proxy on phantasma handles
auth using `.internal` hostnames. See [Internal vs External oauth2-proxy](#internal-vs-external-oauth2-proxy).

### Internal vs external oauth2-proxy

Strictly internal services (like Adguard Home's admin UI) use a **dedicated oauth2-proxy
instance on phantasma** (vINFRA) rather than routing auth_request calls to ordis (vDMZ).

**Why separate proxies:**

The previous design had phantasma (vINFRA, management zone) sending auth_request calls
to ordis (vDMZ, untrusted zone). This meant a management-zone service depended on an
untrusted-zone service for authentication decisions — the trust hierarchy flowing in
the wrong direction. If ordis were compromised, the attacker could manipulate auth
decisions for Adguard Home (an infrastructure DNS management service), creating a
privilege escalation path from vDMZ into vINFRA service control.

With a local oauth2-proxy on phantasma:

- Auth decisions for internal services stay entirely within vINFRA
- The oauth2-proxy → Keycloak OIDC path is intra-zone (no cross-zone dependency)
- A ordis compromise has zero impact on internal service authentication
- The internal proxy can enforce `--allowed-groups=admins` independently of what
  the external proxy allows

**phantasma oauth2-proxy configuration sketch:**

```nix
# On phantasma (vINFRA)
services.oauth2-proxy = {
  enable = true;
  provider = "oidc";
  clientID = "oauth2-proxy-internal";
  keyFile = config.sops.secrets."oauth2-proxy-internal-keyfile".path;
  extraConfig = {
    "oidc-issuer-url" = "https://auth.mutantmell.net/auth/realms/homelab";
    # auth.mutantmell.net resolves to Keycloak microvm via split-horizon DNS.
    # Same issuer URL as ordis's oauth2-proxy — no mismatch possible.
    "allowed-groups" = "admins";         # Only admins access infrastructure UIs
  };
  cookie = {
    secure = true;
    refresh = "1m";
    expire = "30m";
  };
  redirectURL = "https://phantasma.internal.mutantmell.net/oauth2/callback";
  email.domains = [ "*" ];               # Controlled by group restriction instead
};
```

**What uses which proxy:**

| Service                  | Proxy                | Host               | Why                                               |
| ------------------------ | -------------------- | ------------------ | ------------------------------------------------- |
| Jellyfin                 | ordis (external)     | heimdallr (vDMZ)   | Externally reachable via cloud host               |
| Adguard Home admin       | phantasma (internal) | phantasma (vINFRA) | Strictly internal, infrastructure service         |
| Future internal UIs      | phantasma (internal) | vINFRA hosts       | Infrastructure services should not depend on vDMZ |
| Future external services | ordis (external)     | vDMZ hosts         | Externally reachable via cloud host               |

Services that support OIDC natively (see [OIDC Integrations](#oidc-integrations)) bypass
oauth2-proxy entirely and authenticate directly against Keycloak.

---

## Static vs Dynamic Configuration

### What lives in Nix config (declarative, version-controlled)

| Component                | Configuration                                    | File                             |
| ------------------------ | ------------------------------------------------ | -------------------------------- |
| Keycloak service         | Port, hostname, proxy-headers, database          | Keycloak microvm config (vINFRA) |
| step-ca service          | Address, port, provisioners, policy              | step-ca microvm config (vINFRA)  |
| nginx (Keycloak microvm) | Keycloak proxy, ACME proxy to step-ca            | Keycloak microvm config (vINFRA) |
| nginx (ordis)            | Backend proxy, /auth Keycloak proxy              | `ordis/proxy.nix`                |
| oauth2-proxy             | Client ID, issuer URL, upstream, cookie settings | `ordis/proxy.nix`                |
| ACME                     | Server URL, email                                | Per-host ACME config             |
| Firewall rules           | Cross-VLAN forwarding                            | `thebeyond/default.nix`          |
| Sops secrets refs        | Secret file paths                                | Per-host `sops.nix`              |

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
      "redirectUris": ["https://mutantmell.net/oauth2/callback"],
      "defaultClientScopes": ["openid", "profile", "email", "groups"]
    },
    {
      "clientId": "oauth2-proxy-internal",
      "protocol": "openid-connect",
      "publicClient": false,
      "directAccessGrantsEnabled": false,
      "standardFlowEnabled": true,
      "redirectUris": [
        "https://phantasma.internal.mutantmell.net/oauth2/callback"
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
    "oauth2-proxy": [{ "client": "oauth2-proxy", "roles": [] }]
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
  issuerUrl = "https://auth.mutantmell.net/auth/realms/homelab";
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

| Service         | Host                       | Integration Type                                 | Priority    |
| --------------- | -------------------------- | ------------------------------------------------ | ----------- |
| Jellyfin        | heimdallr (vDMZ)           | oauth2-proxy via ordis (already working)         | Done        |
| Adguard Home    | phantasma (vINFRA)         | oauth2-proxy on phantasma (migrating from ordis) | Phase 1     |
| step-ca         | dedicated microvm (vINFRA) | OIDC provisioner (SSH cert plan)                 | Phase 4     |
| Future services | Various                    | Direct OIDC or oauth2-proxy                      | As deployed |

For services that don't support OIDC natively, the oauth2-proxy pattern scales to any
number of backends. Use the appropriate proxy instance based on zone:

- **External services (vDMZ):** auth_request to ordis's oauth2-proxy
- **Internal services (vINFRA):** auth_request to phantasma's oauth2-proxy

Each new backend needs:

- An nginx `location` block with `auth_request /oauth2/auth`
- The oauth2-proxy instance on the appropriate host handles auth
- Optionally, per-location group restrictions via `--allowed-groups` or
  `X-Auth-Request-Groups` header checks

---

## User Account Management

### Account provisioning

User accounts are created dynamically via the Keycloak admin console
(`https://<keycloak-host>.internal/auth/admin/`). No user information is stored in NixOS
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

| Service        | Typical RAM | Notes                                       |
| -------------- | ----------- | ------------------------------------------- |
| Keycloak (JVM) | 512MB–768MB | Java heap + metaspace                       |
| PostgreSQL     | 128MB–256MB | Shared buffers + connections                |
| nginx          | ~10MB       | Reverse proxy (Keycloak + ACME passthrough) |

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
After the refactor, the `extraForwardRules` for ordis → gridr can be expressed clearly.
Before the refactor, the current trust-based forwarding may implicitly allow the traffic
(the pre-refactor `trusted` interfaces set includes both vHOME and vDMZ in the internal
interfaces set). This should be explicitly verified rather than assumed.

### Secure MGMT VLAN Plan

The [vMGMT split](./secure-mgmt-vlan-plan.md) moves phantasma to vINFRA. With Keycloak
also on vINFRA:

- phantasma's oauth2-proxy talks directly to Keycloak (intra-zone, management → management)
- No cross-zone dependency on ordis for internal auth decisions
- The auth infrastructure is consolidated on vINFRA alongside DNS

---

## Implementation Phases

### Phase 1: Provision Keycloak and step-ca microvms on vINFRA

**Goal:** Stand up the target infrastructure on vINFRA.

1. **Provision Keycloak microvm** on a vINFRA host with 2GB RAM, 2 vCPU
2. **Configure Keycloak** service, PostgreSQL, nginx (with /auth proxy)
3. **Add JVM heap limits** (`-Xms256m -Xmx768m`)
4. **Provision step-ca microvm** on a vINFRA host with 512MB RAM, 1 vCPU
5. **Configure step-ca** with nginx for ACME endpoint on :443
6. **Migrate CA key material** from gridr to the new step-ca microvm
7. **Add explicit firewall rules:** ordis → Keycloak microvm:443 (OIDC),
   vDMZ → step-ca microvm:443 (ACME)
8. **Update all ACME client configs** to point at the step-ca microvm's ACME URL
9. **Update ordis's oauth2-proxy config** to point at the new Keycloak microvm
   - Set `cookie.secure = true` (S1)
   - Change `redirectURL` to HTTPS (S2)
   - Remove `skip-jwt-bearer-tokens = true` (S3)
   - Disable `passAccessToken` and `set-authorization-header` unless needed (S7)
   - Replace `email.domains = ["*"]` with `--allowed-groups` once groups exist (S10)
10. **Deploy oauth2-proxy on phantasma** for internal service auth
    - Register `oauth2-proxy-internal` client in Keycloak
    - Store client secret in phantasma's sops secrets
    - Configure with `--allowed-groups=admins`, `cookie.secure = true`
    - Update phantasma's nginx to auth_request against the local oauth2-proxy
      instead of ordis's (eliminates management → untrusted auth dependency)
11. **Verify ACME, OIDC, both oauth2-proxy instances** all work with the new locations
12. **Decommission gridr** (or repurpose) once migration is confirmed

### Phase 2: Realm restructuring

**Goal:** Replace the ad-hoc `external` realm with a properly structured `homelab` realm.

1. **Create `homelab` realm** in Keycloak admin console
2. **Register clients:** `oauth2-proxy`, `step-ca`, `cicd-deploy`
3. **Verify client scope restrictions:** For each client, confirm minimal permissions:
   - `oauth2-proxy`: **No** service account roles, **no** admin API access, Authorization
     Code grant only. The client secret lives on ordis — if ordis is compromised, the
     stolen secret should be useless beyond its intended purpose (exchanging authorization
     codes for user tokens). Verify no `realm-admin` or `manage-users` role mappings.
   - `step-ca`: Authorization Code grant (for OIDC provisioner). No admin roles.
   - `cicd-deploy`: Client Credentials grant (lives on CI/CD server, not ordis — its
     secret is not exposed by a ordis compromise). Scope limited to deploy actions.
4. **Create groups:** `admins`, `media-users`, `deploy`
5. **Add `groups` protocol mapper** (client scope for group claims)
6. **Configure authentication flows:** Conditional MFA for admins
7. **Create initial user accounts**
8. **Update ordis's oauth2-proxy config** to point at `homelab` realm
9. **Update phantasma's proxy config** if realm URL changed
10. **Retire `external` realm** once all clients are migrated
11. **Evaluate keycloak-config-cli:** Optionally set up declarative realm config
    as a systemd service to make the above reproducible

### Phase 3: DNS strategy, external access, and bastion hardening

**Goal:** Implement split-horizon DNS, enable authenticated external access to vDMZ
services via the cloud host, and harden the wg-ba attack surface by splitting SSH to
a dedicated bastion.

1. **Migrate DNS from `.local` to `mutantmell.net` hierarchy** on phantasma (Unbound)
   - Replace `.local` static zone with three zones:
     - `mutantmell.net` (`transparent`) — split-horizon overrides for external names
     - `internal.mutantmell.net` (`static`) — canonical internal names
     - `internal` (`static`) — short convenience aliases
   - Add dual entries for every host (canonical + short alias)
   - Add split-horizon overrides: `auth.mutantmell.net` → Keycloak microvm,
     `mutantmell.net` → ordis (10.0.100.40)
   - Verify resolution from vHOME, vINFRA, and vDMZ clients
2. **Expand step-CA certificate policy** to allow the full naming hierarchy
   - `*.internal.mutantmell.net`, `*.internal`, `*.mutantmell.net`, `mutantmell.net`
3. **Reissue step-CA certs** with new names and dual SANs
   - Each internal host: `<host>.internal.mutantmell.net` + `<host>.internal`
   - Keycloak microvm: `auth.mutantmell.net` + `<keycloak-host>.internal.mutantmell.net`
     - `<keycloak-host>.internal`
   - ordis: `mutantmell.net` + `ordis.internal.mutantmell.net` + `ordis.internal`
4. **Update all host configs** that reference `.local` hostnames
   - nginx `server_name` / virtualHosts
   - ACME server URLs (`<step-ca-host>.internal.mutantmell.net/acme/...`)
   - `networking.extraHosts` entries on hosts with hardcoded fallbacks
   - oauth2-proxy redirect URLs
5. **Configure Keycloak** `hostname = "auth.mutantmell.net"` (strict mode, no
   `hostname-backchannel-dynamic`)
6. **Reconfigure ordis's nginx** with two virtual hosts:
   - `auth.mutantmell.net` — Keycloak proxy for external users
     - Block `/auth/admin/` and `/auth/realms/master/` (S5)
     - Use `X-Forwarded-For $remote_addr` not `$proxy_add_x_forwarded_for` (S13)
   - `mutantmell.net` — services + oauth2-proxy
7. **Reconfigure ordis's oauth2-proxy** with canonical URLs
   - `oidc-issuer-url = "https://auth.mutantmell.net/auth/realms/homelab"` (S4, S6)
   - `redirectURL = "https://mutantmell.net/oauth2/callback"`
   - `cookie.domain = ".mutantmell.net"`
   - No explicit login-url/redeem-url/oidc-jwks-url overrides needed
8. **Update phantasma's oauth2-proxy** issuer URL to `auth.mutantmell.net`, redirect URL
   to `phantasma.internal.mutantmell.net`
9. **Add nginx rate limiting** on ordis for `/auth/` and `/oauth2/` paths (S11)
10. **Provision SSH bastion VM** on vDMZ via Incus (256MB RAM, 1 vCPU, sshd only) (S8)
    - Requires figuring out Incus VM configuration (currently only containers)
    - Key-only auth, `AllowUsers`, minimal NixOS profile
    - No persistent storage (stateless)
11. **Tighten wg-ba firewall rules** (S8)
    - Remove blanket `wg-ba → ordis` rule and SSH port forward
    - Add per-service rules: wg-ba → ordis:443 (HTTPS), wg-ba → bastion:22 (SSH)
12. **Remove SSH daemon from ordis** — no interactive login from external paths
13. **Configure host-level egress filtering on ordis and bastion** — restrict outbound
    connections via custom nftables output chain (see MGMT VLAN plan Phase 4.4):

    **ordis egress allowlist:**
    | Destination | Protocol | Port | Purpose |
    |-------------|----------|------|---------|
    | Keycloak microvm (vINFRA) | TCP | 443 | OIDC token exchange |
    | step-ca microvm (vINFRA) | TCP | 443 | ACME certificate renewal |
    | heimdallr (vDMZ) | TCP | 443, 8096 | Jellyfin proxy target |
    | phantasma (vINFRA) | UDP/TCP | 53 | DNS resolution |
    | Internet | TCP | 443 | OCSP stapling |

    **SSH bastion egress allowlist:**
    | Destination | Protocol | Port | Purpose |
    |-------------|----------|------|---------|
    | vINFRA hosts | TCP | 22 | SSH forwarding to infrastructure |
    | vHOME hosts | TCP | 22 | SSH forwarding to user machines |
    | phantasma (vINFRA) | UDP/TCP | 53 | DNS resolution |

    Everything else is dropped. This limits lateral movement and exfiltration if either
    host is compromised. A compromised ordis can't reach game servers, headscale, or
    arbitrary internet hosts; a compromised bastion can only reach SSH ports.

14. **Deploy cloud host** with nginx + WireGuard + Let's Encrypt cert
    - Wildcard cert for `*.mutantmell.net` (DNS-01 challenge) or per-subdomain certs
    - Import step-CA root cert (to verify ordis's TLS over WireGuard)
    - Proxy by Host header: `auth.mutantmell.net` and `mutantmell.net` both → ordis
    - Strip/overwrite `X-Forwarded-For` at the cloud host (S13)
15. **Test end-to-end (internal):** LAN browser → `mutantmell.net` (DNS: ordis) →
    oauth2-proxy → `auth.mutantmell.net` (DNS: Keycloak) → login → redirect back → service
16. **Test end-to-end (external):** External browser → cloud host → WireGuard → ordis →
    `auth.mutantmell.net` (ordis proxy to Keycloak) → login → redirect back → service
17. **Test SSH path:** Cloud host → WireGuard → bastion → SSH to vDMZ hosts

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

**Security hardening note:** Where backends support OIDC natively, prefer configuring
them to authenticate directly against Keycloak rather than relying solely on ordis's
oauth2-proxy. This creates a defense-in-depth layer: even if ordis is compromised and
the attacker strips `auth_request` from nginx, the backend itself rejects
unauthenticated requests. This matters most for vDMZ services reachable through ordis:

- **Jellyfin** (heimdallr): Supports OIDC via SSO plugin — configure it to validate tokens
  against Keycloak directly. This means even without oauth2-proxy gating, anonymous
  access is rejected by Jellyfin itself.
- **Future services**: Prefer services with native OIDC support when choosing alternatives.
- **Services without OIDC support**: Continue relying on oauth2-proxy; accept the risk.

For each new service:

1. Register client in Keycloak (admin console or keycloak-config-cli)
2. Store client secret in sops
3. Configure service's OIDC settings in Nix (native OIDC preferred over oauth2-proxy)
4. Test login flow
5. Configure group-based access if needed

---

## Security Considerations

> **Context:** Traffic from the internet reaches vDMZ via a WireGuard tunnel from a
> cloud host. Even though WireGuard provides encryption and the firewall limits traffic
> to HTTP(S), the services behind ordis are internet-facing and require hardening
> appropriate for that exposure.

### Architectural assessment

**What the plan gets right:**

The core trust model is sound. The architecture establishes a clear security boundary:
external traffic enters through a single chokepoint (ordis on vDMZ), must pass through
OAuth2 authentication before reaching any backend, and the identity provider (Keycloak)
lives on a more privileged zone (vINFRA) behind an explicit firewall rule. This is the
right topology — the thing that makes authorization decisions should not be on the same
trust level as the things it's protecting.

Separating step-ca and Keycloak into distinct microvms with independent firewall rules
is a good call. Keycloak's attack surface (JVM, PostgreSQL, admin console, complex web
UI) is orders of magnitude larger than step-ca's (a Go binary with a simple API). CA
key material deserves isolation from the most complex component on the network. Having
each microvm serve its own traffic path (Keycloak for OIDC, step-ca for ACME) means a
compromise of either doesn't grant vDMZ access to the other. Cloud-hypervisor microvms
are lightweight enough that the extra nginx instance on the step-ca microvm is
negligible cost for this isolation.

The zone-based firewall model with explicit `extraForwardRules` for cross-zone access
is the right pattern. The default-deny posture (untrusted cannot reach management)
means new vDMZ services don't automatically gain access to Keycloak — an explicit rule
must be added.

**Where the architecture has structural tension:**

1. **ordis is a high-value target with a large role.** ordis handles: TLS termination
   for external traffic, oauth2-proxy (authentication decisions for external services),
   nginx reverse proxy to all externally-reachable backends, and the `/auth` Keycloak
   proxy for external users. SSH access from wg-ba is split off to a dedicated bastion
   microvm (S8), and internal service auth is split to phantasma's own oauth2-proxy, which
   together remove two responsibilities from ordis. If ordis is compromised, the attacker
   gets:
   - Access to every user's Keycloak access tokens (via `passAccessToken`, S7)
   - The ability to bypass OAuth for external backend access (ordis's nginx can proxy directly)
   - A foothold on vDMZ with network access to Keycloak on vINFRA

   Critically, a ordis compromise does **not** affect internal service authentication —
   phantasma's oauth2-proxy operates independently on vINFRA, so Adguard Home and other
   infrastructure UIs remain gated by their own auth path.

   Mitigations (defense in depth, each survives ordis compromise independently):
   - ordis is the _right_ place for external-facing responsibilities — it's the external
     choke point by design, treated as a hardened bastion: minimal packages, no SSH daemon,
     fixes from S1-S7 applied
   - **Host-level egress filtering** (Phase 3, step 12): ordis can only reach its direct
     dependencies (Keycloak, step-ca, heimdallr, DNS, OCSP). No game servers, no headscale,
     no arbitrary internet for C2 or exfiltration
   - **`hostname-admin`** (Phase 1): Keycloak refuses to serve the admin console UI on
     `auth.mutantmell.net`, even if ordis's S5 nginx blocks are removed by an attacker
   - **Native OIDC on vDMZ backends** (Phase 5): backends that authenticate directly
     against Keycloak reject unauthenticated requests even if ordis's auth_request is
     stripped. Jellyfin (heimdallr) is the priority target for this hardening
   - **Minimal client scope** (Phase 2, step 3): the `oauth2-proxy` client secret on
     ordis's disk is useless for admin API access, user enumeration, or token issuance
     without a user present

2. **~~The dual-hostname pattern (internal + external) adds fragile complexity.~~
   Resolved by split-horizon DNS.** The [DNS and Naming Strategy](#dns-and-naming-strategy)
   eliminates this tension. All components use the canonical `auth.mutantmell.net`
   hostname for Keycloak, and split-horizon DNS routes internal clients directly to the
   Keycloak microvm while external clients go through ordis. There is no split URL
   configuration, no `hostname-backchannel-dynamic`, and no hostname matching to get
   wrong. A simple integration test (curl the OIDC discovery endpoint, verify the
   issuer matches `https://auth.mutantmell.net/auth/realms/homelab`) confirms the
   entire chain is consistent.

3. **The "compromised cloud host" threat model deserves explicit treatment.** The cloud
   host is internet-facing and the least trusted component in the chain. The plan
   correctly describes it as a "dumb pipe" but doesn't fully analyze what a compromised
   cloud host can do:
   - **Can do:** See encrypted WireGuard traffic (opaque), attempt brute-force against
     the OAuth login page, attempt to exploit ordis's nginx/TLS stack through the tunnel,
     attempt SSH brute-force against the bastion (key-only auth mitigates this).
   - **Cannot do:** Decrypt WireGuard traffic without the private key, bypass OAuth
     (assuming S3 is fixed), reach anything other than ordis:443 and bastion:22 (firewall
     rules are per-service).
   - **Cannot do (but should be verified):** Reach hosts outside vDMZ via the tunnel.
     The firewall rules restrict wg-ba to specific destination IP:port pairs. However,
     the return traffic rule `{ iifname = "vDMZ.br0"; oifname = "wg-ba"; verdict = "accept"; }`
     allows vDMZ → wg-ba. Confirm that the nftables rules are stateful and that this
     doesn't create an unintended path.

   The cloud host threat model is sound: even full compromise yields only an OAuth login
   page and an SSH prompt (key-only auth). The WireGuard tunnel + per-service firewall
   rules + OAuth + SSH key auth form a reasonable defense-in-depth stack for a homelab.

4. **Single point of failure: Keycloak availability.** If the Keycloak microvm goes
   down, oauth2-proxy cannot validate sessions (refresh fails after `cookie.refresh`
   interval), new logins are impossible, and step-ca's OIDC provisioner stops working.
   (ACME renewals are unaffected — they go directly to step-ca's microvm.) This isn't a
   security concern per se, but availability is part of the security posture — if
   Keycloak goes down and an operator bypasses OAuth to restore access, that bypass could
   leave a hole.

   For a homelab, this is acceptable. Don't build HA Keycloak. But do ensure that
   recovery is well-documented and doesn't require disabling security controls. Keycloak
   data (PostgreSQL) should be backed up regularly; recovery means restoring the microvm
   from backup or re-provisioning from Nix config + database backup.

**Overall verdict:** The architecture is sound for a homelab. The trust boundaries are
in the right places, the firewall model is restrictive by default, and the identity
provider is appropriately isolated from the DMZ. Keycloak and step-ca each have their
own microvm with dedicated firewall rules, so a compromise of one doesn't grant vDMZ
access to the other. The main risks are implementation-level (the S1-S13 findings below)
rather than architectural. The structural point worth tracking is ordis's outsized role
as the internet-facing bastion — it warrants hardening as described above.

### Specific findings: Critical — Must fix before external access

**S1. `cookie.secure = false` in oauth2-proxy (ordis/proxy.nix:69)**

The OAuth session cookie is sent over HTTP. Any network observer between the user and
ordis can steal the cookie and hijack the session. This is currently mitigated by the
fact that all traffic is on the LAN or inside a WireGuard tunnel, but:

- The plan enables external access, where the cloud host terminates TLS and forwards
  to ordis. If the cloud-to-ordis path ever drops to HTTP (misconfiguration, debugging),
  cookies leak.
- Defense in depth: `cookie.secure = true` costs nothing and prevents an entire class
  of mistakes.

**Fix:** Set `cookie.secure = true`. Ensure all paths to ordis use HTTPS (the cloud
host should forward HTTPS-terminated traffic to ordis's HTTPS port, or ordis should
enforce TLS on all cookie-bearing endpoints).

**S2. `redirectURL = "http://ordis.local/oauth2/callback"` (ordis/proxy.nix:63)**

The OAuth2 redirect URI uses `http://`. After the authorization code grant, Keycloak
redirects the user's browser to this URL with the authorization code in the query
string. Over HTTP, the authorization code is visible to any network observer. An
attacker who captures it can exchange it for tokens (the auth code is single-use but
the race window exists).

**Fix:** Change to `https://mutantmell.net/oauth2/callback`. With split-horizon DNS,
internal and external users both use the same domain, so a single HTTPS redirect URI
suffices.

**S3. `skip-jwt-bearer-tokens = true` (ordis/proxy.nix:78)**

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

**S4. ~~`hostname-strict = false` for Keycloak~~ — Resolved by DNS strategy**

The original concern was that Keycloak needed to serve two audiences (internal via
`*.local`, external via the public domain) and might require `hostname-strict = false`,
which would let Keycloak derive its issuer URL from the incoming `Host` header — a
security risk.

The [DNS and Naming Strategy](#dns-and-naming-strategy) eliminates this entirely:

```nix
services.keycloak.settings = {
  hostname = "auth.mutantmell.net";   # Single fixed hostname for all audiences
  # hostname-strict = true;           # Default, leave it
  # No hostname-backchannel-dynamic needed
};
```

All clients (oauth2-proxy on ordis, oauth2-proxy on phantasma, step-ca, user browsers)
use `auth.mutantmell.net` to reach Keycloak. Split-horizon DNS resolves it to the
Keycloak microvm internally and to the cloud host externally. Keycloak runs in strict
mode with a single fixed hostname — no Host header manipulation is possible.

**S5. Keycloak admin console exposed to external users (plan, Phase 3)**

The plan adds a `/auth` proxy location on ordis that forwards all `/auth/*` requests
to the Keycloak microvm. This includes `/auth/admin/` — the Keycloak admin console.
External users can reach the admin login page and attempt credential attacks.

**Fix:** Block the admin console path in ordis's nginx:

```nginx
location /auth/admin/ {
    return 403;
}
location /auth/realms/homelab/protocol/ {
    # Allow: OIDC endpoints needed by oauth2-proxy and user browsers
    proxy_pass https://<keycloak-host>.internal/auth/realms/homelab/protocol/;
    ...
}
```

Whitelist only the paths external users need:

- `/auth/realms/homelab/protocol/openid-connect/*` (login, token, certs, userinfo)
- `/auth/realms/homelab/login-actions/*` (login forms, consent)
- `/auth/resources/*` (Keycloak static assets: CSS, JS, images for login theme)

Block everything else (`/auth/admin/*`, `/auth/realms/master/*`, other realms).

**S6. ~~OIDC issuer mismatch between proxy paths~~ — Resolved by DNS strategy**

The original concern was that oauth2-proxy's `oidc-issuer-url` (internal hostname)
would not match the token issuer (external domain), causing token validation failures.

The [DNS and Naming Strategy](#dns-and-naming-strategy) eliminates this entirely. All
components use `https://auth.mutantmell.net/auth/realms/homelab` as the issuer URL.
Keycloak stamps this in all tokens (`hostname = "auth.mutantmell.net"`), and every
oauth2-proxy instance uses the same URL for `oidc-issuer-url`. Split-horizon DNS
ensures each client reaches Keycloak at this URL regardless of network location.
No URL overrides, no issuer verification skipping, no mismatch possible.

### Specific findings: High — Should fix

**S7. `passAccessToken = true` + `set-authorization-header = true` (ordis/proxy.nix:71,77)**

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

**S8. SSH access from wg-ba — split to dedicated bastion (thebeyond/default.nix:76-82)**

The current config forwards port 22 from the wg-ba WireGuard tunnel to ordis's SSH
daemon. wg-ba connects to the cloud host, which is internet-facing. If the cloud host
is compromised, the attacker gets direct SSH access to ordis — which also runs
oauth2-proxy, nginx, and has a firewall exception to reach Keycloak on vINFRA. SSH
access and web traffic gating should not share a host.

**Fix:** Provision a dedicated SSH bastion microvm on vDMZ:

- **Why vDMZ:** The bastion is reachable from the most untrusted path (internet →
  cloud host → wg-ba). Placing it on vINFRA or vHOME would require letting the
  `isolated` wg-ba tunnel reach a trusted/management zone — strictly worse. vDMZ is
  the right trust level for something exposed to an isolated tunnel. The concern that
  "vDMZ has the biggest attack surface" is about the services _on_ vDMZ, not the zone
  itself; the bastion's attack surface (sshd with key-only auth) is minimal regardless
  of zone placement.

- **Bastion configuration:**
  - Runs only sshd — no nginx, no oauth2-proxy, no other services
  - Key-only auth (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`)
  - Restricted `AllowUsers` to named operator accounts
  - Minimal NixOS profile (no unnecessary packages, no build tools)
  - 256MB RAM, 1 vCPU — lightweight cloud-hypervisor microvm
  - No persistent storage needed (stateless, config from Nix)

- **Firewall changes:**
  - Remove: `{ iifname = "wg-ba"; ip.daddr = "10.0.100.40"; verdict = "accept"; }`
    (blanket access to ordis)
  - Remove: SSH port forward from wg-ba to ordis:22
  - Add: `{ iifname = "wg-ba"; ip.daddr = "10.0.100.40"; tcp.dport = 443; ... }`
    (HTTPS only to ordis)
  - Add: `{ iifname = "wg-ba"; ip.daddr = "<bastion-ip>"; tcp.dport = 22; ... }`
    (SSH only to bastion)

- **ordis hardening:** With SSH moved off, ordis can drop its SSH daemon entirely.
  ordis becomes a pure web proxy with no interactive login capability from external
  paths. Administrative access to ordis uses wg-vpn (trusted) or the bastion as a
  jump host (vDMZ intra-zone).

- **Bastion as jump host:** From the bastion, the operator can SSH to other vDMZ
  hosts (intra-zone). For reaching vHOME or vINFRA hosts, use wg-vpn (trusted) —
  don't add firewall rules from the vDMZ bastion to trusted/management zones.

**S9. ACME provisioner has no authorization (gridr/modules/auth.nix:99-103)**

step-ca's ACME provisioner has no access control beyond network reachability and the
certificate policy (`*.internal.mutantmell.net`, `*.mutantmell.net`, etc.). After the
migration, any vDMZ host that can reach the step-ca microvm can request certificates
for **any** allowed hostname — including `auth.mutantmell.net`,
`phantasma.internal.mutantmell.net`, or `thebeyond.internal`.

A compromised vDMZ service (e.g., a vulnerable web app on heimdallr) could:

1. Request a TLS certificate for `auth.mutantmell.net`
2. Use it to MITM internal traffic (limited impact since vDMZ can't route to vINFRA
   arbitrarily, but still a certificate integrity concern)

**Fix options:**

- **ACME account binding:** Require ACME accounts to be pre-registered (step-ca
  supports external account binding)
- **Narrower certificate policy per zone:** If possible, restrict the ACME
  provisioner so vDMZ-sourced requests can only get certs for names that correspond
  to actual vDMZ services (e.g., `ordis.internal.mutantmell.net`,
  `heimdallr.internal.mutantmell.net`, `mutantmell.net`). This may require multiple ACME
  provisioners or a webhook authorizer.
- **IP-based policy in step-ca:** step-ca supports policy per provisioner; tie
  allowed DNS names to the source network. (step-ca may not support source-IP-based
  policy natively — investigate.)
- **Minimum viable:** Accept the risk for now, since the firewall rule already
  constrains which hosts can reach the ACME endpoint. Document as a known risk.

### Specific findings: Medium — Defense in depth

**S10. `email.domains = ["*"]` (ordis/proxy.nix:64)**

oauth2-proxy allows any email domain. Since Keycloak is the only identity source and
user creation is manual, this is low risk in practice — but it removes a
defense-in-depth layer.

**Fix:** Set to a specific domain once user accounts use a consistent email domain.
Alternatively, use `--allowed-groups` to restrict access by Keycloak group membership
(more granular than email domain filtering).

**S11. No rate limiting on externally-reachable endpoints**

The oauth2-proxy login flow, Keycloak login page, and ACME endpoint are all reachable
from the internet (via wg-ba → ordis). There is no network-level rate limiting.
Keycloak has built-in brute force protection (enabled in the plan's realm config), but:

- oauth2-proxy itself has no rate limiting
- nginx on ordis has no `limit_req` zones configured
- A flood of requests could exhaust resources on ordis or the Keycloak microvm

**Fix:** Add nginx rate limiting on ordis for auth-related paths:

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

**S12. vDMZ → step-ca firewall rule is zone-wide (plan)**

The plan's ACME firewall rule allows any vDMZ host to reach the step-ca microvm. The
OIDC rule is already narrowed to ordis. A compromised vDMZ host could use the ACME
rule to interact with step-ca (requesting certs, see S9).

**Fix (optional):** Restrict ACME source IPs to known vDMZ hosts with ACME certs:

```nix
{
  iifname = "vDMZ.br0";
  oifname = "vINFRA.br0";
  ip.saddr = { "10.0.100.40" "10.0.100.50" "10.0.100.51" };  # ordis.internal, heimdallr.internal, trista.internal
  ip.daddr = "<step-ca-microvm-ip>";
  tcp.dport = 443;
  verdict = "accept";
}
```

This adds maintenance overhead (must update when adding vDMZ hosts) but limits blast
radius. Whether this is worth it depends on how many vDMZ hosts there will be.

**S13. X-Forwarded-For trust chain across multiple proxies**

The external access path has three proxy hops: cloud host nginx → ordis nginx →
Keycloak microvm nginx. Each adds `X-Forwarded-For`. Keycloak needs to know how
many hops to trust (`proxy-headers = "forwarded|xforwarded"` is configured but
without a trusted proxy count). If Keycloak trusts all `X-Forwarded-For` entries,
an attacker can spoof their source IP by including a fake `X-Forwarded-For` header
in the original request.

**Fix:** Configure the cloud host nginx to strip/overwrite `X-Forwarded-For` (set
it rather than append). On ordis and the Keycloak microvm, use
`proxy_set_header X-Forwarded-For $remote_addr` (not `$proxy_add_x_forwarded_for`)
to prevent spoofing from earlier hops, or configure trusted proxy addresses.

### Specific findings: Low / Informational

**S14. ~~Cookie domain scoping~~ — Resolved by DNS strategy**

The original concern was that cookies scoped to the external domain wouldn't apply
when accessing via a different hostname.

With split-horizon DNS, ordis's service vhost is always `mutantmell.net` — internal
and external users access it via the same domain name. Set
`cookie.domain = ".mutantmell.net"` and the cookie works consistently regardless of
access path. phantasma's oauth2-proxy uses `phantasma.internal.mutantmell.net` with cookies
scoped to that domain. No ambiguity.

**S15. Revocation latency**

When a user is disabled in Keycloak, existing oauth2-proxy cookies remain valid until
the next refresh. With `cookie.refresh = "1m"`, the effective revocation window is
~1 minute (the refresh call to Keycloak will fail, invalidating the session). For SSH
certificates, the window is the certificate lifetime (12h in the SSH cert plan). This
is acceptable for a homelab but should be documented.

**S16. ~~phantasma's auth_request passes Host as `$host`~~ — Resolved by design**

This issue is eliminated by the internal oauth2-proxy split. phantasma's nginx now
auth_requests against a local oauth2-proxy instance on phantasma itself, so the Host
header is always `phantasma.internal.mutantmell.net` — which is correct, since the
redirect URI is `https://phantasma.internal.mutantmell.net/oauth2/callback`. No cross-host
confusion is possible.

### Summary of required changes to the plan

| ID  | Finding                                                 | Plan section to update                                 |
| --- | ------------------------------------------------------- | ------------------------------------------------------ |
| S1  | `cookie.secure = true`                                  | Phase 1 (ordis proxy config)                           |
| S2  | HTTPS redirect URL                                      | Phase 1 (ordis proxy config)                           |
| S3  | Remove `skip-jwt-bearer-tokens`                         | Phase 1 (ordis proxy config)                           |
| S4  | ~~Keycloak hostname~~                                   | Resolved by DNS strategy (single fixed hostname)       |
| S5  | Block admin console in ordis proxy                      | Phase 3 (ordis `auth.mutantmell.net` vhost)            |
| S6  | ~~OIDC issuer mismatch~~                                | Resolved by DNS strategy (single canonical issuer URL) |
| S7  | Disable `passAccessToken` / `set-authorization-header`  | Phase 1 (ordis proxy config)                           |
| S8  | Split SSH to dedicated bastion microvm on vDMZ          | Phase 3 (bastion + firewall tightening)                |
| S9  | Investigate ACME provisioner authorization              | Phase 1 (step-ca config)                               |
| S10 | Replace `email.domains = ["*"]` with group-based access | Phase 2 (realm restructuring)                          |
| S11 | Add nginx rate limiting                                 | Phase 3 (ordis nginx config)                           |
| S12 | Consider narrowing ACME firewall source IPs             | Phase 1 (firewall rules)                               |
| S13 | Fix X-Forwarded-For trust chain                         | Phase 3 (proxy chain config)                           |

---

## Complete File Change List

| File                                                 | Phase   | Changes                                                                                                                                                   |
| ---------------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keycloak microvm config (new, on vINFRA host)        | 1       | New microvm: Keycloak, PostgreSQL, nginx (/auth proxy), sops secrets                                                                                      |
| step-ca microvm config (new, on vINFRA host)         | 1       | New microvm: step-ca, nginx (ACME endpoint), CA key material, sops secrets                                                                                |
| SSH bastion microvm config (new, on vDMZ host)       | 3       | New microvm: sshd only, key-only auth, minimal profile, 256MB RAM                                                                                         |
| `hosts/thebeyond/default.nix`                        | 1, 3    | Add ordis → Keycloak + vDMZ → step-ca FW rules (Phase 1); replace wg-ba blanket rule + SSH port forward with per-service rules (Phase 3); add DNS entries |
| `hosts/erebonia/guests/ordis/proxy.nix`              | 1, 2, 3 | Update OIDC issuer URL, update realm, add `/auth` proxy location, split oauth2-proxy URLs                                                                 |
| `hosts/erebonia/guests/ordis/` (SSH removal)         | 3       | Remove SSH daemon / openssh config from ordis                                                                                                             |
| `hosts/thebeyond/guests/phantasma/modules/proxy.nix` | 1       | Deploy local oauth2-proxy, update nginx auth_request to local proxy (remove ordis dependency)                                                             |
| `hosts/thebeyond/guests/phantasma/sops.nix`          | 1       | Add `oauth2-proxy-internal` client secret                                                                                                                 |
| `hosts/thebeyond/guests/phantasma/modules/dns.nix`   | 3       | Replace `.local` zone with `internal.mutantmell.net` + `internal` + `mutantmell.net` zones                                                                |
| Per-host ACME configs                                | 1, 3    | Update ACME server URL to step-ca microvm; update cert names from `*.local` to `*.internal.mutantmell.net` with dual SANs                                 |
| `hosts/erebonia/guests/ordis/sops.nix`               | 2       | Update oauth2-proxy key file for new realm                                                                                                                |
| gridr config (retire/repurpose)                      | 1       | Remove Keycloak, step-ca, and associated nginx/sops config                                                                                                |
| `llm-notes/ssh-certificates-sso-plan.md`             | —       | Update Keycloak and step-ca placement (both vINFRA)                                                                                                       |
