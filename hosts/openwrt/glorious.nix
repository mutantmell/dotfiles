# TP-Link EAP615-Wall v1 — ADU router/AP (UNCONFIRMED: verify before deploying)
# Runs firewall + DHCP/DHCPv6/RA, no mesh, no batman-adv
{owrtData}: {
  type = "simpleAP";
  hostname = "glorious";
  profile = "tplink_eap615-wall-v1";
  target = "ramips";
  subtarget = "mt7621";
  hostId = 20;
  vlanId = 31;
  timezone = owrtData.defaultTimezone;
  country = owrtData.defaultCountry;
  encryption = owrtData.defaultEncryption;
  # Keep dnsmasq (removed by default) — glorious serves DHCP for the ADU network
  extraPackages = ["dnsmasq" "odhcpd-ipv6only"];
  extraConfig = {
    # Firewall — stricter defaults than mesh APs (acts as a gateway)
    firewall = {
      defaults = {
        _type = "defaults";
        syn_flood = true;
        input = "REJECT";
        output = "ACCEPT";
        forward = "REJECT";
      };
      zone_lan = {
        _type = "zone";
        name = "lan";
        input = "ACCEPT";
        output = "ACCEPT";
        forward = "ACCEPT";
      };
      zone_wan = {
        _type = "zone";
        name = "wan";
        network = ["wan" "wan6"];
        input = "REJECT";
        output = "ACCEPT";
        forward = "REJECT";
        masq = true;
        mtu_fix = true;
      };
      fwd_lan_wan = {
        _type = "forwarding";
        src = "lan";
        dest = "wan";
      };
    };

    # DHCP — serves IPv4 and IPv6 for ADU network
    dhcp = {
      dnsmasq = {
        _type = "dnsmasq";
        domainneeded = true;
        boguspriv = true;
        localise_queries = true;
        rebind_protection = true;
        rebind_localhost = true;
        local = "/lan/";
        domain = "lan";
        expandhosts = true;
        authoritative = true;
        readethers = true;
        leasefile = "/tmp/dhcp.leases";
        nonwildcard = true;
        localservice = true;
        ednspacket_max = 1232;
        cachesize = 1000;
      };
      lan = {
        _type = "dhcp";
        interface = "lan";
        start = 100;
        limit = 150;
        leasetime = "12h";
        dhcpv4 = "server";
        dhcpv6 = "server";
        ra = "server";
        ra_flags = ["managed-config" "other-config"];
        ignore = false;
      };
    };

    # LEDs disabled
    system = {
      led_status = {
        _type = "led";
        name = "status-off";
        sysfs = "white:status";
        trigger = "none";
        default = 0;
      };
      led_phy0 = {
        _type = "led";
        name = "phy0-off";
        sysfs = "mt76-phy0";
        trigger = "none";
        default = 0;
      };
      led_phy1 = {
        _type = "led";
        name = "phy1-off";
        sysfs = "mt76-phy1";
        trigger = "none";
        default = 0;
      };
    };
  };
}
