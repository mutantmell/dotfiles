{lib}: let
  pki = ./pki;
in {
  network = import ./network.nix {inherit lib;};
  keys = builtins.fromJSON (
    builtins.readFile ./keys.json
  );
  # Static UID/GID registry, two ranges:
  #   - System users / groups (400-499): service-shaped, allocated in the
  #     reserved system range (SYS_UID_MIN=500 in modules/common/default.nix).
  #     nixpkgs static IDs stop at 326; dynamic system users start at 500.
  #     See: github.com/NixOS/nixpkgs/blob/master/nixos/modules/misc/ids.nix
  #   - Normal users (1000+): interactive role accounts (shell, home dir,
  #     used by humans via su/ssh). Coordinated here so file ownership
  #     stays coherent across any host that mounts shared media (virtiofs
  #     today, NFS RW if it ever ships).
  users = {
    # System users
    media = {
      uid = 400;
      gid = 400;
    };
    llm = {
      uid = 401;
      gid = 401;
    };
    # Normal users (interactive role accounts).
    # Allocated at 1100+ to leave 1000-1099 free for personal accounts
    # (e.g., mutantmell is uid 1000 on edith).
    mediaops = {
      uid = 1100;
    };
  };
  pki = {
    root = pki + "/root_ca.crt";
    intermediate = pki + "/intermediate_ca.crt";
    sshUserCA = pki + "/ssh_user_ca.pub";
    sshHostCA = pki + "/ssh_host_ca.pub";
    # Offline-generated fleet X5C CA cert; gates machine mTLS enrollment.
    # The X5C provisioner on basel and the fleet enrollment-cert assertions
    # both reference this directly.
    fleetX5cCA = pki + "/fleet_x5c_ca.crt";
    # JWK break-glass SSH-user-cert provisioner material (foundational-identity-
    # resilience Phase A). `key` is the public JWK; `encryptedKey` is the
    # password-encrypted private JWK as JWE JSON serialization (as emitted by
    # `step crypto jwk create`; step-ca.nix joins its segments into the compact
    # form step-ca wants). Both are safe to commit — the offline JWK password
    # (operator passage vault) is the actual secret. Generate with:
    #   step crypto jwk create admin_jwk.pub.json admin_jwk.enc --kty EC --crv P-256
    adminJwk = {
      key = pki + "/admin_jwk.pub.json";
      encryptedKey = pki + "/admin_jwk.enc";
    };
  };
  # k3s control-plane CAs — cluster-scoped (erebonia's own self-signed roots),
  # deliberately distinct from the homelab-wide step-ca trust in `pki` above
  # (bootstrap decision #3: k3s keeps its own CA root, not a step-ca
  # intermediate). Only the public CA *certs* live here; the matching private
  # keys are sops (hosts/erebonia/secrets/k3s-ca.yaml). The flake owns these so a
  # rebuilt/recovered erebonia regenerates its leaf certs under the *same* CAs
  # (trust reproduces; edith's kubeconfig + any client certs stay valid) and so
  # clients trust :6443 without a post-boot copy. Adopted from erebonia's already
  # initialized cluster — k3s requires CA data not change once initialized, so
  # these are imported as-is, never regenerated.
  k3s.erebonia = let
    d = ./k3s/erebonia;
  in {
    serverCa = d + "/server-ca.crt";
    clientCa = d + "/client-ca.crt";
    requestHeaderCa = d + "/request-header-ca.crt";
    etcdServerCa = d + "/etcd-server-ca.crt";
    etcdPeerCa = d + "/etcd-peer-ca.crt";
  };
  fleetEnrollmentCerts = let
    certDir = ./fleet-x5c-certs;
    certFiles =
      if builtins.pathExists certDir
      then builtins.readDir certDir
      else {};
    parseName = filename: let
      m = builtins.match "(.+)\\.crt" filename;
    in
      if m != null
      then builtins.head m
      else null;
  in
    lib.listToAttrs (lib.filter (x: x != null)
      (lib.mapAttrsToList (
          filename: _: let
            hostname = parseName filename;
          in
            if hostname != null
            then {
              name = hostname;
              value = certDir + "/${filename}";
            }
            else null
        )
        certFiles));
  hostCerts = let
    certDir = ./host-certs;
    certFiles =
      if builtins.pathExists certDir
      then builtins.readDir certDir
      else {};
    parseName = filename: let
      m = builtins.match "(.+)-cert\\.pub" filename;
    in
      if m != null
      then builtins.head m
      else null;
  in
    lib.listToAttrs (lib.filter (x: x != null)
      (lib.mapAttrsToList (
          filename: _: let
            hostname = parseName filename;
          in
            if hostname != null
            then {
              name = hostname;
              value = certDir + "/${filename}";
            }
            else null
        )
        certFiles));
}
