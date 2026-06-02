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
    # Null until operator generates and commits the offline CA cert.
    # Once fleet_x5c_ca.crt is committed, the X5C provisioner on basel activates.
    fleetX5cCA = let
      path = pki + "/fleet_x5c_ca.crt";
    in
      if builtins.pathExists path
      then path
      else null;
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
