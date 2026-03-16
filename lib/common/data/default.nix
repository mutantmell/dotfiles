{lib}: {
  network = import ./network.nix {inherit lib;};
  keys = builtins.fromJSON (
    builtins.readFile ./keys.json
  );
  sshCA = let
    path = ./ssh-ca.json;
  in
    if builtins.pathExists path
    then builtins.fromJSON (builtins.readFile path)
    else null;
  pki.root = ./pki/root_ca.crt;
  pki.intermediate = ./pki/intermediate_ca.crt;
}
