{lib}: {
  network = import ./network.nix {inherit lib;};
  keys = builtins.fromJSON (
    builtins.readFile ./keys.json
  );
  certs.root = ./certs/root_ca.crt;
  certs.intermediate = ./certs/intermediate_ca.crt;
}
