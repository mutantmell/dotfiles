{pkgs, ...}: {
  # router6 renders the shared record model directly as kresd policies.
  router6.dns = {
    inherit (pkgs.mmell.lib.data.dns) localZones localRecords;
  };
}
