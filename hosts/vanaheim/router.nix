{ config, ... }:
{
  router = {
    enable = true;
    dns.upstream = "10.0.10.2";
    firewall.extraForwards = [
      {
        ip.saddr = "10.55.10.32";
        ip.daddr = "10.100.0.3";
        verdict = "accept";
      }
      {
        iifname = [
          "vDMZ.lan"
        ];
        oifname = "wg-ba";
        verdict = "accept";
      }
      {
        iifname = "wg-ba";
        ip.daddr = "10.55.100.40";
        verdict = "accept";
      }
    ];
    firewall.extraPreRoutes = [
      {
        iifname = "wg-ba";
        tcp.dport = "22";
        verdict.dnat = "10.55.100.40";
      }
    ];
    firewall.extraPostRoutes = [
      {
        oifname = "wg-ba";
        masquerade = true;
      }
      {
        iifname = "wg-ba";
        ip.daddr = "10.55.100.40";
        masquerade = true;
      }
    ];
    topology = {
      "enp0s13f0u3u1" = {
        network = { type = "disabled"; required = false; };
        vlans = {
          "vMGMT.lan" = {
            tag = 10;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.55.10.1/24"]; trust = "management"; };
          };
          "vHOME.lan" = {
            tag = 20;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.55.20.1/24"]; trust = "trusted"; };
          };
          "vADU.lan" = {
            tag = 31;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.55.31.1/24"]; dns = "resolved"; trust = "untrusted"; };
          };
          "vDMZ.lan" = {
            tag = 100;
            network = {
              type = "static";
              static-addresses = ["10.55.100.1/24"];
              dhcp.enable = true;
              trust = "untrusted";
            };
          };
        };
        batmanDevice = "bat0";
        mtu = "1536";
      };
      bat0 = {
        batman = {
          gatewayMode = "off";
          routingAlgorithm = "batman-v";
        };
        network = { type = "disabled"; required = false; };
        vlans = {
          "vMGMT.bat0" = {
            tag = 10;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.10.1/24"]; trust = "management"; };
          };
          "vHOME.bat0" = {
            tag = 20;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.20.1/24"]; trust = "trusted"; };
          };
          "vGUEST.bat0" = {
            tag = 30;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.30.1/24"]; trust = "untrusted"; };
          };
          "vIOT.bat0" = {
            tag = 40;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.40.1/24"]; trust = "untrusted"; };
          };
          "vGAME.bat0" = {
            tag = 41;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.41.1/24"]; trust = "untrusted"; };
          };
        };
      };
    };
  };
  }
