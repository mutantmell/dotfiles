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
}
