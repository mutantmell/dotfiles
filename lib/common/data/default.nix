{lib}: let
  pki = ./pki;
in {
  network = import ./network.nix {inherit lib;};
  keys = builtins.fromJSON (
    builtins.readFile ./keys.json
  );
  pki = {
    root = pki + "/root_ca.crt";
    intermediate = pki + "/intermediate_ca.crt";
    sshUserCA = pki + "/ssh_user_ca.pub";
    sshHostCA = pki + "/ssh_host_ca.pub";
  };
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
