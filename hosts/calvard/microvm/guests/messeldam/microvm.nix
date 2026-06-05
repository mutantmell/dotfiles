{lib, ...}: {
  microvm.hypervisor = "cloud-hypervisor";
  microvm.vsock.cid = 6;

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
    {
      source = "/persist/guests/messeldam/static";
      mountPoint = "/static";
      tag = "static";
      proto = "virtiofs";
    }
  ];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [
    {
      autoCreate = true;
      mountPoint = "/persist";
      image = "/persist/guests/messeldam/images/persist.img";
      size = 100 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  # Keycloak (JVM + PostgreSQL) was removed in Phase 3 of the Authelia
  # migration. The remaining auth stack — Authelia (~50MB) + lldap (~30MB) +
  # nginx — fits comfortably in 512MB / 1 vCPU.
  #
  # The persist volume below stays at 100GB: it's a sparse image (PostgreSQL was
  # the only large consumer and its persist dir is gone, so real usage is now
  # <1GB), and it holds the *only* copy of live auth state (lldap users +
  # Authelia keys/sessions + ACME certs). Recreating it to reclaim the cap would
  # wipe that state, so the reclaim is deliberately deferred — the unused cap
  # costs nothing on a sparse image.
  microvm.mem = 512;
  microvm.vcpu = 1;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-11-messeldam";
      mac = "5E:0B:11:06:00:01";
    }
  ];
}
