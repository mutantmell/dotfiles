# SSH Certificates with Keycloak SSO — Future Plan

> **Status:** Future work. Not part of the current secure-mgmt-vlan plan.
> The current plan uses MAC allowlisting as the vMGMT admission gate.
> This document captures the intended replacement.

## Motivation

MAC allowlisting has two problems:

1. **Not a real security boundary.** MAC addresses are trivially spoofable —
   any device on the LAN can claim a known MAC.
2. **Tied to hardware, not identity.** Building a new desktop (or swapping a NIC)
   means losing access until the new MAC is manually added to the allowlist.

SSH certificates fix both: they prove *who you are* cryptographically, independent
of what hardware you're using.

## Architecture overview

```
┌──────────┐     OIDC      ┌──────────────┐
│  Admin    │──────────────▸│   Keycloak   │  (OIDC / OAuth2 provider)
│  Desktop  │◂─────────────│   (vINFRA)   │
│           │  short-lived  └──────────────┘
│           │  SSH cert              │
│           │                        │ signs certs via
│           │                        ▼
│           │               ┌──────────────┐
│           │               │   step-ca     │  (SSH certificate authority)
│           │               │   or vault    │
│           │               └──────────────┘
│           │
│           │─── SSH w/ cert ──▸  vMGMT / vINFRA hosts
└──────────┘                     (TrustedUserCAKeys configured)
```

### Components

1. **Keycloak** — runs on a vINFRA host (e.g. alfheim alongside DNS, or a
   dedicated VM). Acts as the OIDC provider. Users authenticate with
   username + password + MFA (TOTP/WebAuthn).

2. **SSH Certificate Authority** — either:
   - **step-ca** (Smallstep): purpose-built for SSH certificates, has native
     OIDC provisioner support. `step ssh certificate` handles the full flow.
   - **HashiCorp Vault**: SSH secrets engine can sign certificates after Vault
     authenticates the user via its OIDC auth method.

   step-ca is simpler for this use case unless Vault is already deployed.

3. **Admin desktop** — runs `step ssh login` (or equivalent), which:
   - Opens a browser to Keycloak for authentication
   - On success, receives a signed SSH certificate (short-lived, e.g. 12h)
   - Writes the cert to `~/.ssh/id_ed25519-cert.pub`
   - Normal `ssh` commands then present the cert automatically

4. **Target hosts** — NixOS hosts on vMGMT/vINFRA configure:
   ```nix
   services.openssh = {
     extraConfig = ''
       TrustedUserCAKeys /etc/ssh/ca.pub
       # Optional: map certificate principals to local users
       AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
     '';
   };
   ```
   They trust the CA's public key, not individual user keys. No
   `authorized_keys` management needed.

## Authentication flow

```
1. Admin runs: step ssh login admin@home.local
2. Browser opens → Keycloak login (password + MFA)
3. Keycloak issues OIDC token → step-ca validates it
4. step-ca signs an SSH certificate:
     - Principal: "admin" (mapped from OIDC claim)
     - Validity: 12 hours
     - Extensions: permit-pty, permit-agent-forwarding
5. Certificate written to ~/.ssh/id_ed25519-cert.pub
6. Admin runs: ssh yggdrasil.local
     - sshd verifies cert signature against TrustedUserCAKeys
     - Checks principal "admin" against AuthorizedPrincipalsFile
     - Grants access
```

## Relationship to the vMGMT VLAN plan

The vMGMT VLAN topology from the current plan stays **exactly the same**. The
change is purely about the admission gate:

| Aspect                   | Current (MAC)         | Future (SSH cert)           |
|--------------------------|-----------------------|-----------------------------|
| Network topology         | vMGMT VLAN            | vMGMT VLAN (unchanged)      |
| Who can reach mgmt ports | MAC-allowlisted hosts | Any host on vMGMT*          |
| Authentication           | SSH key (static)      | SSH certificate (short-lived)|
| Identity binding         | Hardware (NIC MAC)    | User (Keycloak account)     |
| MFA                      | None                  | Keycloak-enforced           |
| Revocation               | Remove MAC from list  | Revoke in Keycloak / short cert TTL |

\* vMGMT admission could also move from MAC allowlisting to 802.1X (RADIUS
backed by Keycloak), but that's a separate enhancement.

### What NOT to over-invest in now

Because the MAC allowlist is temporary, the current plan should:

- Keep MAC rules in **one place** (a single list in the router config) — don't
  scatter MAC checks across multiple firewall rules or host configs
- **Not build tooling** around MAC management (no scripts to add/remove MACs)
- **Not add MAC-based identity** to other systems (e.g. don't use MAC to
  determine DNS names or NFS access)

This keeps the eventual swap to certificates minimal: replace one router
firewall rule with "allow vMGMT subnet" and deploy TrustedUserCAKeys to hosts.

## Implementation sketch (for when this becomes active)

### Phase 1: Deploy Keycloak
- NixOS module: `services.keycloak`
- Run on a vINFRA host (alfheim or dedicated VM)
- Configure realm, users, MFA policies
- Expose on internal DNS: `auth.home.local`

### Phase 2: Deploy step-ca with OIDC provisioner
- NixOS service: step-ca with OIDC provisioner pointing at Keycloak
- Generate SSH CA keypair; distribute `ca.pub` to all managed hosts
- Configure provisioner to map Keycloak groups → SSH principals

### Phase 3: Configure target hosts
- `TrustedUserCAKeys /etc/ssh/ca.pub` on all vMGMT/vINFRA hosts
- `AuthorizedPrincipalsFile` to control which principals can log in where
- This can be a shared NixOS module: `modules/common/ssh-ca.nix`

### Phase 4: Client setup
- Install `step` CLI on admin machines
- `step ssh login` for interactive use
- Optionally: PAM integration so certificate is refreshed on desktop login

### Phase 5: Remove MAC allowlist
- Update router firewall: vMGMT no longer filters by MAC
- Security now comes from: network isolation (VLAN) + identity (certificate)
