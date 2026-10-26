# Restore Jellyfin LDAP authentication

Status: operator-managed integration recorded during the Authelia migration. Current Nix declares transport, service and persistent data, not plugin installation or its mutable settings. Confirm the installed Jellyfin/LDAP plugin version and current state before applying the procedure; UI labels/XML schema may differ. No live reconstruction is claimed here.

## Ownership and prerequisites

Jellyfin runs on oracion and binds lldap on messeldam directly; this is not Authelia OIDC. The LDAP Authentication plugin and its `LDAP-Auth.xml` are operator-managed beneath Jellyfin's persistent data, currently `/var/lib/jellyfin`. Avoid declaratively overwriting a file Jellyfin rewrites. Before recovery, retain a consistent backup of Jellyfin data/plugin configuration and an available **local administrator account**; preserve its authentication provider until LDAP web and client access is accepted.

The bind credential is named **`jellyfin-ldap-bind-password`**, managed on messeldam through its existing sops/operator workflow. Retrieve it only through the approved operator secret workflow and enter it privately in the Jellyfin dashboard. Do not put it in a command argument, issue, screenshot, repository file or a new oracion sops bootstrap solely for this plugin. A backup of Jellyfin's mutable plugin settings may contain credentials and must be protected accordingly.

## Transport and recorded settings

Read the current registry's `messeldam` IPv4 rather than guessing an address from a hostname. lldap currently listens on IPv4 port **3890** (`hosts/calvard/microvm/guests/messeldam/modules/lldap.nix`), with host input restricted to oracion's IPv4; oracion has the matching egress rule. The APP-to-management path also needs the scoped BT8-gateway flow. Do not reapply old temporary UCI files or grant an entire zone LDAP access.

The recorded integration uses plain LDAP over this restricted IPv4 path, without SSL/StartTLS. This is an existing transport choice, not an instruction to enable a TLS checkbox against a non-TLS listener. Use the registry IPv4 in the plugin so dual-stack resolution does not select an unsupported IPv6 listener. From oracion, `nc -z <messeldam-registry-ipv4> 3890` should succeed; repeat from an unauthorized source and confirm it is denied. Network success does not establish a successful LDAP bind or correct authorization.

| Setting          | Recorded value/contract                         |
| ---------------- | ----------------------------------------------- |
| Server/port      | Current messeldam IPv4, TCP 3890                |
| Bind DN          | `uid=jellyfin,ou=people,dc=mutantmell,dc=net`   |
| Bind password    | Operator-supplied `jellyfin-ldap-bind-password` |
| Base DN          | `dc=mutantmell,dc=net`                          |
| Base user filter | `(objectClass=person)`                          |
| Media membership | `cn=media-users,ou=groups,dc=mutantmell,dc=net` |

The original membership expression was `memberOf=cn=media-users,ou=groups,dc=mutantmell,dc=net`. Verify the installed plugin's enabled-user/group-filter semantics and use valid parenthesized LDAP filters in fields that require them. For a combined person-and-membership filter, validate `(&(objectClass=person)(memberOf=cn=media-users,ou=groups,dc=mutantmell,dc=net))` using the plugin test before relying on it. **Membership granting media access must not automatically grant Jellyfin administration.** Inspect administrator filters separately; keep local administration and only explicitly approved LDAP administrator mapping. Do not copy an ambiguous “admin/enabled filter” value into both fields.

## Reconstruction and acceptance

1. Compare the current plugin/data backup and installed version. In Dashboard → Plugins → Catalog, install **LDAP Authentication** if missing, then restart Jellyfin through the operator path and confirm the local admin still works.
2. Open the plugin settings, enter the recorded connection/bind/base settings and validate the installed version's membership and administrator mappings. Use the plugin's server/settings test; it must bind and find the intended user set before saving or changing any user's authentication provider.
3. In lldap administration at `https://ldap.internal`, verify the intended human users and `media-users` membership. Do not repurpose/delete the read-only `jellyfin` service bind user.
4. Sign in through Jellyfin's HTTPS web UI and a mobile/TV client using a member account. Verify intended libraries/playback, normal non-administrator permissions, and that a nonmember cannot gain LDAP media access. Existing deliberately local accounts are a separate policy and must not be silently deleted.
5. Restart and retest persistence plus the local-admin fallback. Record version, redacted settings, membership/privilege results and transport tests in private operator evidence; keep credentials and mutable XML out of PRs.

If authentication or authorization differs from the intended policy, restore the known-good plugin settings/data through the local admin/recovery path and retest. Account membership changes may not invalidate existing Jellyfin sessions immediately; contain an incident using [identity incident response](authelia-incident-response.md) rather than assuming a new-login test proves session revocation.
