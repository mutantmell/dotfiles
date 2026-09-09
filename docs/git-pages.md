# Internal Forgejo Pages

Creil runs git-pages from the pinned nixpkgs revision (currently 0.9.1), with
filesystem storage and a shared Caddy HTTPS frontend. New repositories do not
need DNS records, host configuration, a Pages branch, or a service account on
Creil. CI publishes the output directory directly over HTTPS.

- Project: `https://USER.pages.internal/PROJECT/` maps to
  `https://forgejo.internal/USER/PROJECT.git`.
- User homepage: `https://USER.pages.internal/` maps to the user's `pages`
  repository (the default Pages branch convention is `pages`).
- Bootstrap upload endpoint: `pages.internal`.

Publishing checks the token's push permission on the mapped Forgejo repository.
The server only accepts repository sources under `https://forgejo.internal/`.
Pages are readable by anyone with network access to Creil, including content
published from private repositories. Forgejo visibility is not a viewing ACL.
Projects under the same user hostname share a browser origin; use separate
owners if projects must be isolated from one another.

## Infrastructure and deployment

1. Deploy Phantasma's DNS configuration: the `pages.internal` redirect zone
   resolves the apex and arbitrary subdomains to Creil over IPv4 and IPv6.
2. Deploy Basel's step-ca policy: X.509 issuance also permits
   `*.pages.internal`. SSH issuance policy is unchanged.
3. Deploy Creil. Caddy replaces nginx for the existing Forgejo hostnames and
   serves Pages on the same ports 80/443. Forgejo stays on loopback port 3000;
   git-pages and the certificate permission endpoints are loopback-only.

Use the repository's normal microVM deployment process for those guests. This
change does not apply live configuration itself. Expect a brief frontend
interruption while nginx is replaced and Caddy obtains its initial certificates.
Keep the previous NixOS generation available for rollback.

Caddy obtains individual certificates from Basel's existing ACME provisioner
using HTTP-01, including on-demand certificates for published user domains.
There are no wildcard certificates or DNS provider credentials. Basel must be
able to resolve Pages DNS and reach Creil on port 80. Caddy's permission relay
allows only one-label `*.pages.internal` domains already containing a site;
unknown domains do not trigger certificate issuance. The fixed apex obtains a
certificate at startup, allowing the first authenticated upload to bootstrap a
user domain. The first browser visit then obtains that domain's certificate.

Caddy access and error logs go to the journal, with `Forge-Authorization`
removed explicitly in addition to its standard credential-header redaction.

The existing Woodpecker worker network policy already permits Creil:443.
Publishing containers and browsers must trust the internal CA. The host's CA
trust is not automatically inherited by arbitrary CI container images.

State is persisted under `/persist` through impermanence:

- `/var/lib/git-pages`: site contents and manifests; include this in backups.
- `/var/lib/caddy`: ACME accounts, certificates, and renewal state.

These use Creil's existing 25 GiB persistent volume alongside Forgejo. Monitor
free space as usage grows. Persistence is not an independent backup; existing
host/volume backup coverage should be confirmed before relying on it.

## Publish a project

Build with the site's public path configured. For Vite project sites:

```sh
npm ci
npm run build -- --base=/PROJECT/
```

Use a pinned `git-pages-cli` release in the publishing environment. Put a
Forgejo token restricted to the intended repository, with repository write
permission and user-read permission (`read:user`), in a Woodpecker secret
exposed as `GIT_PAGES_TOKEN`. The server checks both `/api/v1/user` and the
repository permission endpoint. Consult the
Forgejo token UI for the scope names in the deployed version. Never expose this
secret to untrusted pull requests; publish only after successful trusted main
branch builds. No token belongs in the Nix configuration.

```sh
git-pages-cli https://USER.pages.internal/PROJECT/ \
  --server pages.internal \
  --upload-dir dist
```

`--server` takes a hostname, not a URL. It connects using TLS SNI
`pages.internal` but retains `Host: USER.pages.internal`, so the very first
upload succeeds before a certificate exists for the user hostname. It is safe
to keep this option for later uploads. The CLI reads `GIT_PAGES_TOKEN` from the
environment.

For a custom publishing image, include the public root from
`lib/common/data/pki/root_ca.crt`
in its certificate bundle during the image build, following the existing
`hosts/erebonia/k3s/woodpecker-images.nix` internal-CA pattern. Alternatively mount a trusted
bundle and set `SSL_CERT_FILE=/path/to/bundle.pem` in the publishing container.
Do not disable TLS verification. A native Woodpecker pipeline and publishing
image selection remain repository-level work; this infrastructure does not
change the game's pipeline.

## Verify and troubleshoot

```sh
dig pages.internal A
dig USER.pages.internal AAAA
curl -I https://pages.internal/
# On Creil:
systemctl status git-pages caddy
journalctl -u git-pages -u caddy --since '10 minutes ago'
# After publishing:
curl -f https://USER.pages.internal/PROJECT/
```

An unknown user's TLS connection is expected to fail until its first upload.
An upload returning 401 should be checked against the mapped owner/repository
and token push permission. An unknown-authority error means the client or
server is missing CA trust, not that TLS should be bypassed.

Development checks:

```sh
./scripts/agent-preflight.sh git-pages git-pages-config phantasma-dns-real
```

The Pages integration test uses the actual service and frontend with a local
test certificate issuer and a Forgejo API fixture. It checks first-upload TLS
routing, permission rejection, publication, domain restrictions, and persisted
content after service restarts. The config check verifies the actual production ACME issuer, root trust,
HTTP-01 selection, and Forgejo upload-limit exceptions. Production ACME
issuance should also be smoke
tested after deployment against Basel.

References: [git-pages server configuration](https://git-pages.org/running-a-server/),
[git-pages-cli](https://codeberg.org/git-pages/git-pages-cli).
