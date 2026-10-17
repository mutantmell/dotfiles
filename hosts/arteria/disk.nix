{config, ...}: {
  # Old erebonia used /dev/sda. Confirm the disk on the installer and replace
  # this with its /dev/disk/by-id path before formatting if hardware changed.
  imports = [(import ../../profiles/disko/tmpfs.nix {disk = "/dev/sda";})];

  # Match thebeyond: unlock locally, without depending on the network gateway
  # we are bringing up. The deployment wrapper installs the key on the ESP.
  boot.initrd.systemd.enable = true;
  boot.initrd.supportedFilesystems = ["vfat"];
  boot.initrd.luks.devices.cryptroot = {
    device = "/dev/disk/by-partlabel/disk-main-persist";
    allowDiscards = true;
    keyFile = "/secrets/disk.key:/dev/disk/by-partlabel/disk-main-ESP";
    keyFileTimeout = 10;
  };

  common.impermanence.enable = true;
  fileSystems."/nix" = {
    device = "${config.common.impermanence.persistDir}/nix";
    fsType = "none";
    options = ["bind"];
    neededForBoot = true;
  };

  # Kea's DynamicUser state includes both DHCPv4/v6 leases and its server
  # identity. Preserve resolver state alongside it, as on thebeyond.
  environment.persistence.${config.common.impermanence.persistDir}.directories = [
    "/var/lib/private/kea"
    "/var/lib/knot-resolver"
  ];

  # Restore the console password on every boot without bind-mounting shadow,
  # which password tools need to replace atomically. Provision this hash from
  # the installer; never put password material into the Nix store.
  users.users.root.hashedPasswordFile = "${config.common.impermanence.persistDir}/secrets/root-password";

  system.activationScripts.createBootSecrets = ''
    mkdir -p /boot/secrets
    chmod 700 /boot/secrets
  '';
}
