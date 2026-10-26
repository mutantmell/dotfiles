# Identity resilience and certificate boundaries

Authelia and lldap on messeldam provide the rich identity service; step-ca on basel handles certificates. They remain foundational services outside the Kubernetes workload lifecycle. Moving authentication to APP or k3s is not an approved migration from the old brainstorming notes.

Operator recovery has three layers: authorized raw SSH keys, the `admin-jwk` SSH certificate provisioner independent of Authelia, and daily OIDC-issued SSH certificates. See [JWK access](step-ca-jwk-break-glass.md). The JWK path still needs a controlled outage acceptance record; Nix rendering alone is not evidence of a live login.

SSH host public keys and signed host certificates are repository data; private identities remain in operator storage or target runtime state. X5C fleet enrollment replaces the abandoned SSHPOP-to-x509 idea. Provisioning and renewal serve different purposes: rotating enrollment material does not revoke an already issued client certificate.

Use [incident response](authelia-incident-response.md) to coordinate account containment, consumer sessions, and certificate lifetimes. There is no universal immediate revocation guarantee. Service-specific mTLS is deliberate: fleet push endpoints use it, while not every internal service call does. Zone rules and endpoint controls must match each path rather than relying on an absolute “no mTLS” statement.

Retaining raw-key recovery and a possible IdP-independent Perses login floor are deferred decisions. Restricting recovery access before independent console access has been tested would remove a needed repair path. Revisit the shelved resilience work when external ingress or stronger operator-access restrictions are actively planned.

Current Authelia OIDC policies for step-ca, Perses and k3s are explicitly
`one_factor`. [MFA work](https://forgejo.internal/mutantmell-net/dotfiles/issues/241) must address all
selected current admin consumers, including kubectl authentication, with recovery
and operator enrollment before enforcement.
