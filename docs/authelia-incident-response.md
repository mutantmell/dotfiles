# Authelia and lldap incident response

Status: containment guidance. Version-specific session invalidation needs validation before it becomes a command runbook.

Authelia/lldap run on messeldam; step-ca and Perses consume OIDC, while Jellyfin binds lldap directly. Use operator access and keep secrets out of logs and issue attachments.

1. Identify the affected user, groups, clients, sessions, and suspected credential types. Preserve relevant journal and VictoriaLogs records (`authelia-main.service`).
2. Stop new access by changing the affected account/password/group membership through lldap administration. Check each consumer's actual refresh/cache behavior; do not assume an existing session re-binds LDAP on every request. Do not remove service bind accounts as a substitute for containing a human account.
3. Inventory already-issued OIDC tokens, application sessions, SSH certificates, and fleet certificates separately. Disabling an account does not retroactively invalidate every artifact. Contain affected services or network paths where immediate revocation is unavailable.
4. Use the pinned Authelia version's supported invalidation mechanism after testing it on disposable state. The old note's assumption that portal sessions can be deleted from the storage SQLite database is unverified. Do not delete guessed tables or rotate the storage-encryption key as a session-wipe recipe: that key also protects durable authentication data. Make a consistent backup before storage maintenance.
5. If issuer signing material is compromised, rotate it through the sops/operator deployment workflow and verify consumer JWKS refresh and old-token rejection. Existing application sessions may outlive token checks. Coordinate bind-password changes on both ends. Use the separate JWK SSH path if the IdP is unavailable.
6. Confirm that old credentials fail, new authorized login works, and temporary network restrictions have been removed when safe. Record remaining validity windows and the incident timeline without recording secrets.

Rotating an enrollment certificate does not invalidate a previously issued mTLS certificate. Short lifetimes limit exposure; immediate containment may require endpoint/firewall changes. Headscale is not deployed; future node and pre-auth-key revocation is separate from lldap account handling.
