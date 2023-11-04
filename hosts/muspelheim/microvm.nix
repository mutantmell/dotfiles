{ config, pkgs, microvm, ... }:

{
  microvm.autostart = [
    "surtr2"
  ];

  microvm.vms = {
    surtr2 = {
      inherit pkgs;

      config = {
        # It is highly recommended to share the host's nix-store
        # with the VMs to prevent building huge images.
        microvm.shares = [{
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }];
        microvm.mem = 1024;
        microvm.balloonMem = 1024;
        microvm.vcpu = 1;
        microvm.interfaces = [{
          type = "bridge";
          bridge = "br100";
          id = "ens3";
          mac = "5E:41:3F:F4:AB:B4";
        }];

        # Any other configuration for your MicroVM
        # [...]
        environment.systemPackages = [
          pkgs.home-manager
        ];
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = false;
            PermitRootLogin = "prohibit-password";
            KbdInteractiveAuthentication = false;
          };
        };

        users.extraUsers.root.openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
        ];
      };
    };
  };
}
