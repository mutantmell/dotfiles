# Test runner for dotfiles
#
# Run all tests: ./scripts/run-checks.sh (avoid `nix flake check` — OOM risk)
# Run one: nix build .#checks.x86_64-linux.<name>
# Run interactively: nix build .#checks.x86_64-linux.<name>.driverInteractive && ./result/bin/nixos-test-driver
# Run unit tests: nix-instantiate --eval --strict tests/lib/<file>.nix
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
  disko ? null,
}:
# Router tests in sub-module
(import ./router6.nix {inherit pkgs lib;})
// {
  # Incus integration tests
  deployd = import ./modules/deployd.nix {inherit pkgs lib;};
  incus-container = import ./modules/incus-container.nix {inherit pkgs lib;};
  incus-vm = import ./modules/incus-vm.nix {inherit pkgs lib disko;};

  # Disko profile validation
  disko-tmpfs = let
    profile = import ../profiles/disko/tmpfs.nix {};
  in
    pkgs.runCommand "disko-tmpfs-check" {
      profileJson = builtins.toJSON profile;
    } ''
      echo "tmpfs disko profile validated successfully"
      echo "$profileJson" > $out
    '';

  disko-btrfs = let
    profile = import ../profiles/disko/btrfs.nix {inherit lib;};
  in
    pkgs.runCommand "disko-btrfs-check" {
      profileJson = builtins.toJSON profile;
    } ''
      echo "btrfs disko profile validated successfully"
      echo "$profileJson" > $out
    '';

  disko-btrfs-l2arc = let
    profile = import ../profiles/disko/btrfs.nix {
      l2arcSize = "32G";
      inherit lib;
    };
  in
    pkgs.runCommand "disko-btrfs-l2arc-check" {
      profileJson = builtins.toJSON profile;
    } ''
      echo "btrfs+l2arc disko profile validated successfully"
      echo "$profileJson" > $out
    '';

  # Kata kernel config drift check — verifies all required symbols are =y
  kata-kernel-config = let
    symbols = import ../packages/kata-kernel-nested/builtin-symbols.nix;
    inherit (pkgs.mmell.kata-kernel-nested) configfile;
  in
    pkgs.runCommand "kata-kernel-config-check" {} ''
      fail=0
      ${lib.concatMapStrings (sym: ''
        if ! grep -q '^CONFIG_${sym}=y$' ${configfile}; then
          echo "FAIL: CONFIG_${sym} is not =y in $(realpath ${configfile})"
          grep -E '^(# )?CONFIG_${sym}( |=)' ${configfile} || \
            echo "  (symbol absent — kconfig deps may have changed)"
          fail=1
        fi
      '') symbols}
      if [ $fail -ne 0 ]; then
        echo
        echo "Kata kernel override drifted. Either some override silently"
        echo "downgraded to =m/=n, or a parent symbol's deps changed."
        echo "Re-run the verification in llm-notes/wip/kata-nested-kvm-plan.md"
        echo "(section 4) and update builtin-symbols.nix."
        exit 1
      fi
      echo ok > $out
    '';

  # cc-sandbox unit tests
  cc-sandbox = let
    python = pkgs.python3.withPackages (ps: [ps.requests ps.pytest]);
  in
    pkgs.runCommand "cc-sandbox-tests" {} ''
      cp ${../packages/cc-sandbox/cc_sandbox.py} cc_sandbox.py
      cp ${../packages/cc-sandbox/test_cc_sandbox.py} test_cc_sandbox.py
      ${python}/bin/python -m pytest test_cc_sandbox.py -v
      echo ok > $out
    '';
}
