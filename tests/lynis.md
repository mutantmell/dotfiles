# Lynis Security Audit

Lynis is a security auditing tool for Linux systems. It can be run against
a deployed router (or any NixOS host) to check system hardening.

## Running Lynis on a deployed host

```bash
# On the target host (e.g. thebeyond):
nix-shell -p lynis --run 'sudo lynis audit system --quick'

# Or via SSH:
ssh thebeyond 'nix-shell -p lynis --run "sudo lynis audit system --quick"'
```

The report is written to `/var/log/lynis-report.dat` by default. Use
`--report-file /tmp/lynis-report.dat` to write it elsewhere.

## Running Lynis in a VM test

A NixOS VM test can boot a router6-configured system and run Lynis inside it.
This was evaluated (2026-03-11) and found to be more useful as a one-off audit
than a permanent CI test, because:

- Lynis findings rarely change between runs (sysctl/firewall config is static)
- The hardening index is somewhat arbitrary and many suggestions are not
  actionable in a NixOS context (auditd, malware scanner, legal banners, etc.)
- Testing thebeyond's real config requires stubbing sops secrets and
  impermanence, making the test fragile to config changes

To run a one-off VM audit, create a test file like:

```nix
# tests/modules/lynis-audit.nix
{ pkgs ? import <nixpkgs> {}, lib ? pkgs.lib }:
pkgs.testers.nixosTest {
  name = "lynis-audit";
  nodes.router = { config, pkgs, lib, ... }: {
    imports = [ ../../modules/router6 ];
    virtualisation.vlans = [ 1 2 ];
    router6 = {
      enable = true;
      ulaPrefix = "fdc6:55f2:0a5e::/48";
      zones = {
        external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
        trusted = {
          icmpEcho = "enable";
          accessTo = [ "trusted" "external" ];
          inputRules = [{ verdict = "accept"; }];
        };
      };
      dns = {
        upstream = [ "1.1.1.1" ];
        useDHCPFallback = false;
        localDomain = "test.local";
      };
      topology = {
        eth1 = {
          hardwareName = "eth1";
          network = {
            type = "static"; addresses = [ "203.0.113.1/24" ];
            zone = "external"; nat.enable = true;
          };
        };
        eth2 = {
          hardwareName = "eth2";
          network = {
            type = "static"; addresses = [ "10.0.10.1/24" ];
            zone = "trusted"; dhcp.enable = true;
          };
        };
      };
    };
    environment.systemPackages = [ pkgs.lynis ];
  };
  testScript = ''
    start_all()
    router.wait_for_unit("nftables.service")
    router.succeed(
        "lynis audit system --no-colors --quick "
        "--report-file /tmp/lynis-report.dat "
        "--log-file /tmp/lynis.log"
    )
    index = router.succeed(
        "grep '^hardening_index=' /tmp/lynis-report.dat | cut -d= -f2"
    ).strip()
    print(f"Hardening index: {index}")
    for line in router.succeed(
        "grep '^warning' /tmp/lynis-report.dat || true"
    ).splitlines():
        print(f"  {line}")
    for line in router.succeed(
        "grep '^suggestion' /tmp/lynis-report.dat || true"
    ).splitlines():
        print(f"  {line}")
  '';
}
```

Then run it (without registering in router6.nix):

```bash
nix build -f tests/modules/lynis-audit.nix --print-build-logs
```

## Audit results (2026-03-11)

Hardening index: **69** (thebeyond config, post-hardening)

### Accepted sysctl deviations

| Sysctl                             | Lynis wants | Actual | Justification                                                                                                                                                                                                                                                                 |
| ---------------------------------- | ----------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kernel.modules_disabled`          | 1           | 0      | Setting to 1 is irreversible until reboot. Router needs runtime module loading (bonding, batman-adv, 8021q, bridge, wireguard, nf_conntrack). Can be addressed later with `security.lockKernelModules = true` after enumerating all required modules in `boot.kernelModules`. |
| `kernel.unprivileged_bpf_disabled` | 1           | 2      | Value 2 provides identical protection (unprivileged BPF blocked) but is reversible by root. Since root can call `bpf()` directly regardless, irreversibility adds no security.                                                                                                |
| `net.ipv4.conf.all.forwarding`     | 0           | 1      | False positive. IP forwarding is the fundamental function of a router. Lynis assumes endpoint hardening. Security is provided by nftables zone-based firewall with default-drop policy.                                                                                       |

### Accepted warnings

| Warning                                        | Justification                                                                                                                                                                                                     |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AUTH-9283: Account without password            | NixOS defaults root to SSH-key-only auth (shadow field `!`). Consider adding a sops-managed `hashedPasswordFile` with `neededForUsers = true`.                                                                    |
| NETW-3015: Promiscuous interface (bond0, bat0) | VLAN sub-interfaces of bond0/bat0 are bridge members. The kernel propagates promiscuous mode from bridged VLAN children to parent devices. Required for bridge/VLAN operation; nftables is the security boundary. |

### Suggestions (informational, not actionable in CI)

| Category | Suggestion                                                                   |
| -------- | ---------------------------------------------------------------------------- |
| AUTH     | Password hashing rounds, PAM strength testing, password age, locked accounts |
| FILE     | Separate partitions for /home, /tmp, /var                                    |
| USB      | Disable USB storage drivers                                                  |
| NETW     | Uncommon protocols (dccp, sctp, rds, tipc)                                   |
| LOGG     | Log rotation, remote syslog                                                  |
| BANN     | Legal banner in /etc/issue                                                   |
| ACCT     | Process accounting, sysstat, auditd                                          |
| TIME     | NTP daemon (chrony is running but Lynis may not detect it)                   |
| FINT     | File integrity monitoring (AIDE, OSSEC, etc.)                                |
| HRDN     | Malware scanner (rkhunter, chkrootkit)                                       |
| BOOT     | Harden systemd services (`systemd-analyze security`)                         |
| KRNL     | Sysctl tweaks (see accepted deviations above)                                |
| PKGS     | Package audit tool                                                           |
| TOOL     | Automation tools                                                             |

### Hardening applied from this audit

The following sysctls were added to `modules/router6/default.nix` as a direct
result of this audit:

```nix
# ICMP redirect hardening
"net.ipv4.conf.all.send_redirects" = 0;
"net.ipv4.conf.default.send_redirects" = 0;
"net.ipv4.conf.all.accept_redirects" = 0;
"net.ipv4.conf.default.accept_redirects" = 0;
"net.ipv6.conf.all.accept_redirects" = 0;
"net.ipv6.conf.default.accept_redirects" = 0;

# Log martian packets
"net.ipv4.conf.all.log_martians" = 1;
"net.ipv4.conf.default.log_martians" = 1;

# Kernel hardening
"dev.tty.ldisc_autoload" = 0;
"fs.protected_fifos" = 2;
"fs.protected_regular" = 2;
"fs.suid_dumpable" = 0;
"kernel.kptr_restrict" = 2;
"kernel.sysrq" = 0;
"net.core.bpf_jit_harden" = 2;
```

These are tested by `router6-sysctl-properties` (pure eval) and verified by
the firewall VM tests.
