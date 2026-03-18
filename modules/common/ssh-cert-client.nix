{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.common.ssh-cert-client;
  inherit (pkgs.mmell.lib.data) pki;
  rootCaFingerprint = builtins.hashFile "sha256" pki.root;
in {
  options.common.ssh-cert-client = {
    enable = lib.mkEnableOption "SSH certificate client configuration";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [pkgs.step-cli];

    # Trust the internal root CA for TLS
    security.pki.certificateFiles = [pki.root];

    # step-cli defaults: CA URL, fingerprint, and default provisioner
    environment.etc."step-cli/defaults.json".text = builtins.toJSON {
      ca-url = "https://basel.internal";
      fingerprint = rootCaFingerprint;
      root = "/etc/ssl/certs/ca-certificates.crt";
      provisioner = "keycloak";
    };

    environment.variables.STEPPATH = "/etc/step-cli";

    # SSH client: present certificates, trust host CA
    programs.ssh = {
      extraConfig = ''
        Host *.internal *.internal.mutantmell.net
          User root
          IdentityFile ~/.ssh/id_ed25519
          CertificateFile ~/.ssh/id_ed25519-cert.pub
      '';
      knownHosts."host-ca" = {
        hostNames = ["*.internal" "*.internal.mutantmell.net" "*.mutantmell.net"];
        publicKeyFile = pki.sshHostCA;
        certAuthority = true;
      };
    };
  };
}
