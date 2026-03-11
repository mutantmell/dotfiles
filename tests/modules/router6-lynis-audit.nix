# NixOS integration test: Lynis security audit of router6
#
# Boots a router6-configured VM and runs Lynis to verify system hardening.
# Asserts on:
# - Minimum hardening index score
# - No unexpected warnings (whitelists VM-environment false positives)
# - Specific sysctl and firewall hardening checks
#
# Run: nix build .#checks.x86_64-linux.router6-lynis-audit
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-lynis-audit";

  nodes = {
    router = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [../../modules/router6];

      virtualisation.vlans = [1 2];

      router6 = {
        enable = true;
        ulaPrefix = "fdc6:55f2:0a5e::/48";

        zones = {
          external = {
            icmpEcho = "disable";
            accessTo = [];
            inputRules = [];
          };
          trusted = {
            icmpEcho = "enable";
            accessTo = ["trusted" "external"];
            inputRules = [{verdict = "accept";}];
          };
        };

        dns = {
          upstream = ["1.1.1.1"];
          useDHCPFallback = false;
          localDomain = "test.local";
        };

        topology = {
          eth1 = {
            hardwareName = "eth1";
            network = {
              type = "static";
              addresses = ["203.0.113.1/24"];
              zone = "external";
              nat.enable = true;
            };
          };
          eth2 = {
            hardwareName = "eth2";
            network = {
              type = "static";
              addresses = ["10.0.10.1/24"];
              zone = "trusted";
              dhcp.enable = true;
            };
          };
        };

        firewall = {
          extraInputRules = [];
          extraForwardRules = [];
        };
      };

      # Set a root password so AUTH-9283 doesn't fire
      users.users.root.hashedPassword = "$y$j9T$SALT$HASH.placeholder.for.test";

      environment.systemPackages = [pkgs.lynis];
    };
  };

  testScript = ''
    start_all()

    router.wait_for_unit("network-online.target")
    router.wait_for_unit("nftables.service")

    # ==========================================================================
    # Run Lynis audit
    # ==========================================================================
    print("Running Lynis security audit...")

    router.succeed(
        "lynis audit system --no-colors --quick "
        "--report-file /tmp/lynis-report.dat "
        "--log-file /tmp/lynis.log "
        "2>&1 | tee /tmp/lynis-stdout.txt"
    )

    # ==========================================================================
    # Parse results
    # ==========================================================================
    report = router.succeed("cat /tmp/lynis-report.dat")

    index_str = router.succeed(
        "grep '^hardening_index=' /tmp/lynis-report.dat | cut -d= -f2"
    ).strip()
    index = int(index_str)
    print(f"Hardening index: {index}")

    warnings_raw = router.succeed(
        "grep '^warning\\[\\]=' /tmp/lynis-report.dat || true"
    ).strip()
    warnings = [w for w in warnings_raw.splitlines() if w.strip()]
    print(f"Warnings: {len(warnings)}")
    for w in warnings:
        print(f"  {w}")

    suggestions_raw = router.succeed(
        "grep '^suggestion\\[\\]=' /tmp/lynis-report.dat || true"
    ).strip()
    suggestions = [s for s in suggestions_raw.splitlines() if s.strip()]
    print(f"Suggestions: {len(suggestions)}")

    # Print sysctl deviations for visibility
    sysctl_details = router.succeed(
        "grep '^details\\[\\]=KRNL-6000' /tmp/lynis-report.dat || true"
    ).strip()
    if sysctl_details:
        print("Sysctl deviations from Lynis profile:")
        for line in sysctl_details.splitlines():
            print(f"  {line}")

    # ==========================================================================
    # Assert: hardening index
    # ==========================================================================
    MIN_SCORE = 60
    assert index >= MIN_SCORE, \
        f"Hardening index {index} below minimum {MIN_SCORE}"
    print(f"PASS: Hardening index {index} >= {MIN_SCORE}")

    # ==========================================================================
    # Assert: no unexpected warnings
    # ==========================================================================
    # AUTH-9283 is whitelisted — in the VM test environment, the root
    # hashedPassword placeholder may not be recognized by Lynis as valid.
    # In production, sops-nix sets a real password.
    WHITELISTED_WARNINGS = {"AUTH-9283"}

    real_warnings = []
    for w in warnings:
        whitelisted = False
        for wl in WHITELISTED_WARNINGS:
            if wl in w:
                whitelisted = True
                break
        if not whitelisted:
            real_warnings.append(w)

    assert not real_warnings, \
        "Unexpected Lynis warnings:\n" + "\n".join(real_warnings)
    print(f"PASS: No unexpected warnings ({len(warnings)} whitelisted)")

    # ==========================================================================
    # Assert: nftables firewall is active with drop policy
    # ==========================================================================
    router.succeed("nft list chain inet filter input | grep 'policy drop'")
    router.succeed("nft list chain inet filter forward | grep 'policy drop'")
    fw = router.succeed(
        "grep '^firewall_active=' /tmp/lynis-report.dat"
    ).strip()
    assert "firewall_active=1" in fw, f"Firewall not active: {fw}"
    print("PASS: nftables firewall active, drop policy")

    # ==========================================================================
    # Assert: sysctl hardening applied
    # ==========================================================================

    # Redirect hardening
    router.succeed("sysctl -n net.ipv4.conf.all.send_redirects | grep '^0$'")
    router.succeed("sysctl -n net.ipv4.conf.all.accept_redirects | grep '^0$'")
    router.succeed("sysctl -n net.ipv4.conf.default.accept_redirects | grep '^0$'")
    router.succeed("sysctl -n net.ipv6.conf.all.accept_redirects | grep '^0$'")
    router.succeed("sysctl -n net.ipv6.conf.default.accept_redirects | grep '^0$'")
    print("PASS: ICMP redirect hardening")

    # Martian logging
    router.succeed("sysctl -n net.ipv4.conf.all.log_martians | grep '^1$'")
    router.succeed("sysctl -n net.ipv4.conf.default.log_martians | grep '^1$'")
    print("PASS: Martian packet logging")

    # Reverse path filtering
    router.succeed("sysctl -n net.ipv4.conf.all.rp_filter | grep '^1$'")
    print("PASS: Reverse path filtering")

    # Kernel hardening
    router.succeed("sysctl -n dev.tty.ldisc_autoload | grep '^0$'")
    router.succeed("sysctl -n fs.protected_fifos | grep '^2$'")
    router.succeed("sysctl -n fs.protected_regular | grep '^2$'")
    router.succeed("sysctl -n fs.suid_dumpable | grep '^0$'")
    router.succeed("sysctl -n kernel.kptr_restrict | grep '^2$'")
    router.succeed("sysctl -n kernel.sysrq | grep '^0$'")
    router.succeed("sysctl -n net.core.bpf_jit_harden | grep '^2$'")
    print("PASS: Kernel hardening sysctls")

    # Routing (must be enabled for a router)
    router.succeed("sysctl -n net.ipv4.conf.all.forwarding | grep '^1$'")
    router.succeed("sysctl -n net.ipv6.conf.all.forwarding | grep '^1$'")
    router.succeed("sysctl -n net.ipv6.conf.all.accept_ra | grep '^0$'")
    print("PASS: Routing sysctls")

    # ==========================================================================
    # Summary
    # ==========================================================================
    print("")
    print("=" * 70)
    print("LYNIS AUDIT COMPLETE")
    print(f"  Hardening index: {index}")
    print(f"  Warnings: {len(warnings)} ({len(warnings)} whitelisted)")
    print(f"  Suggestions: {len(suggestions)}")
    print("  All assertions passed")
    print("=" * 70)
  '';
}
