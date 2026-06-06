{
  config,
  pkgs,
  lib,
  ...
}: let
  certs = pkgs.mmell.lib.data.k3s.erebonia;

  # Same persistent datastore subvolume as k3s/default.nix; the control-plane
  # TLS material lives under it (server/tls and server/tls/etcd).
  dataDir = "/persist/k3s";
  tlsDir = "${dataDir}/server/tls";

  # The control-plane CA material the flake OWNS and reproduces. k3s mints AND
  # ROTATES every leaf under these (the client-*/serving-* certs, the *.nochain
  # derivations, the etcd leaf certs) — we never seed or pin those, because
  # pinning leaves would fight k3s' built-in cert rotation (bootstrap decision
  # #3). We own: 5 CAs (server / client / request-header / etcd-server /
  # etcd-peer) + the ServiceAccount issuer key (service.key), all seeded into
  # tls below — plus the server token (via tokenFile, NOT seeded; see its note).
  #
  # NOT owned: `service.current.key`. That is k3s' *active* SA signing key, which
  # k3s manages and recreates itself for key rotation — it is not part of the
  # custom-CA input set (k3s' own generate-custom-ca-certs.sh writes service.key
  # only). `service.key` is the accumulating issuer-key file, so it preserves
  # verification of already-issued tokens on its own; owning it is enough.
  #
  # Public CA certs: committed plaintext (lib/common/data/k3s/erebonia), 0644.
  pubCerts = [
    {
      dst = "server-ca.crt";
      src = certs.serverCa;
    }
    {
      dst = "client-ca.crt";
      src = certs.clientCa;
    }
    {
      dst = "request-header-ca.crt";
      src = certs.requestHeaderCa;
    }
    {
      dst = "etcd/server-ca.crt";
      src = certs.etcdServerCa;
    }
    {
      dst = "etcd/peer-ca.crt";
      src = certs.etcdPeerCa;
    }
  ];

  # Private keys: sops-decrypted, 0600. service.key is the SA issuer key (a bare
  # RSA key file, not a CA) — losing it breaks verification of every issued
  # ServiceAccount token, so the flake owns it; service.current.key is excluded
  # (k3s-managed, see above). `secret` is the sops key name; `dst` is the path
  # under tls (etcd keys nest).
  privKeys = [
    {
      dst = "server-ca.key";
      secret = "server-ca.key";
    }
    {
      dst = "client-ca.key";
      secret = "client-ca.key";
    }
    {
      dst = "request-header-ca.key";
      secret = "request-header-ca.key";
    }
    {
      dst = "etcd/server-ca.key";
      secret = "etcd-server-ca.key";
    }
    {
      dst = "etcd/peer-ca.key";
      secret = "etcd-peer-ca.key";
    }
    {
      dst = "service.key";
      secret = "service.key";
    }
  ];

  # Seed-if-absent: on a live erebonia every file already exists, so this is a
  # no-op; on a fresh/recovered host it lays down the adopted CAs *before* k3s
  # starts, so k3s adopts them instead of generating new self-signed roots. It
  # never overwrites an existing file — k3s' rotated leaves (and a rotated
  # service.current.key) are left untouched.
  seedScript = pkgs.writeShellApplication {
    name = "k3s-ca-seed";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      set -euo pipefail
      install -d -m 0700 "${tlsDir}" "${tlsDir}/etcd"
      seed() {
        # seed <dst-rel> <src> <mode>
        dst="${tlsDir}/$1"
        if [ ! -e "$dst" ]; then
          install -m "$3" "$2" "$dst"
          echo "seeded $dst"
        fi
      }
      ${lib.concatMapStringsSep "\n      "
        (c: ''seed "${c.dst}" "${c.src}" 0644'')
        pubCerts}
      ${lib.concatMapStringsSep "\n      "
        (k: ''seed "${k.dst}" "${config.sops.secrets.${k.secret}.path}" 0600'')
        privKeys}
    '';
  };
in {
  # Private CA/SA keys. mode 0600, owner root (k3s runs as root; the seed copies
  # them into the tls dir as root). Decryptable by admin + sv_erebonia per the
  # .sops.yaml creation rule for hosts/erebonia/secrets/. The server token (used
  # via tokenFile, not seeded) shares the same sops file.
  sops.secrets =
    lib.genAttrs (map (k: k.secret) privKeys)
    (_: {
      sopsFile = ../secrets/k3s-ca.yaml;
      mode = "0600";
    })
    // {
      "server-token" = {
        sopsFile = ../secrets/k3s-ca.yaml;
        mode = "0600";
      };
    };

  # The k3s server token: the PBKDF2 passphrase that encrypts the datastore
  # "bootstrap data" (which holds the CA keys above). Owning it makes the
  # cluster's identity fully flake-reproducible — a from-flake rebuild yields the
  # same token, so it composes with datastore snapshot restore (k3s can't decrypt
  # an existing snapshot's bootstrap data under a mismatched token). Handed to
  # k3s via tokenFile; k3s reads it directly and derives node-token + bootstrap
  # encryption from it, so unlike the CAs it is NOT seeded into tls.
  services.k3s.tokenFile = config.sops.secrets."server-token".path;

  # Run after the datastore subvolume (tmpfiles `v` in default.nix) exists and
  # after sops has placed the keys; strictly before k3s so adoption wins over
  # k3s' first-boot self-signed CA generation. requiredBy makes a seed failure
  # block k3s rather than let it silently mint a new, untrusted CA.
  systemd.services.k3s-ca-seed = {
    description = "Adopt flake-owned k3s control-plane CAs (seed if absent)";
    before = ["k3s.service"];
    requiredBy = ["k3s.service"];
    after = ["systemd-tmpfiles-setup.service" "sops-install-secrets.service"];
    wants = ["sops-install-secrets.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe seedScript;
    };
  };
}
