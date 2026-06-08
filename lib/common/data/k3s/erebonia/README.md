# erebonia k3s control-plane CA certs (public)

The **public** CA certificates for erebonia's k3s control plane. Committed
plaintext and exposed as `data.k3s.erebonia.*` (see `../../default.nix`).
The matching **private keys** live in sops at
`hosts/erebonia/secrets/k3s-ca.yaml` — never here.

These are erebonia's own self-signed control-plane CAs, kept deliberately
separate from the homelab-wide step-ca trust in `../../pki/` (bootstrap
decision #3). They were **adopted** from erebonia's already-initialized
cluster; k3s requires CA data not change once initialized, so they are
imported as-is and never regenerated.

Required files (5), each the public cert from erebonia
`/var/lib/rancher/k3s/server/tls/`:

| file here               | source on erebonia          |
| ----------------------- | --------------------------- |
| `server-ca.crt`         | `tls/server-ca.crt`         |
| `client-ca.crt`         | `tls/client-ca.crt`         |
| `request-header-ca.crt` | `tls/request-header-ca.crt` |
| `etcd-server-ca.crt`    | `tls/etcd/server-ca.crt`    |
| `etcd-peer-ca.crt`      | `tls/etcd/peer-ca.crt`      |

Everything else under `tls/` (the `client-*`/`serving-*` leaves, the
`*.nochain.crt` derivations, the etcd leaf certs) is minted and rotated by
k3s from these CAs and is **not** owned by the flake.
