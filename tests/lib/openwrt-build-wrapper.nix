{
  pkgs,
  lib,
}: let
  fakeBuilder = pkgs.writeShellScriptBin "openwrt-build" ''
    set -euo pipefail
    printf 'builder-args:'
    printf ' <%s>' "$@"
    printf '\n'
    if [ -n "''${OPENWRT_SECRETS_FILE:-}" ]; then
      printf 'environment-secrets:%s\n' "$OPENWRT_SECRETS_FILE"
    fi
    for arg in "$@"; do
      if [ "$arg" = "--secrets-file" ]; then
        previous_was_secrets=true
      elif [ "''${previous_was_secrets:-false}" = true ]; then
        [ "$arg" != "-" ] || { IFS= read -r secret; printf 'stdin-secret:%s\n' "$secret"; }
        previous_was_secrets=false
      fi
    done
  '';
  fakeDeployer = pkgs.writeShellScriptBin "openwrt-deploy" "exit 0";
  testPkgs =
    pkgs
    // {
      mmell =
        pkgs.mmell
        // {
          openwrt-builder = fakeBuilder;
          openwrt-deployer = fakeDeployer;
        };
    };
  config = pkgs.runCommand "openwrt-wrapper-test-config" {} ''
    mkdir -p "$out"
    echo '{"buildId":"test"}' > "$out/build.json"
  '';
  devices.bt8bridge = {
    target = "mediatek";
    subtarget = "filogic";
    profile = "asus_zenwifi-bt8";
    role = "wirelessBridge";
  };
  app = import ../../apps/openwrt {
    pkgs = testPkgs;
    openwrtDevices = devices;
    openwrtConfigurations.bt8bridge = config;
    openwrtVmConfigurations.bt8bridge = config;
  };
in
  pkgs.runCommand "openwrt-build-wrapper-tests" {
    nativeBuildInputs = [pkgs.git pkgs.ripgrep];
  } ''
    set -euo pipefail
    wrapper=${app.openwrt-build.program}

    expect_failure() {
      local expected="$1"
      shift
      if "$wrapper" bt8bridge "$@" >output 2>&1; then
        echo "unexpected success: $*" >&2
        exit 1
      fi
      rg -q -- "$expected" output
    }

    expect_success() {
      "$wrapper" bt8bridge "$@" >output 2>&1
      rg -q 'builder-args:' output
    }

    # Help must reach the underlying CLI without repository discovery, secrets,
    # or even creating the artifact-directory hierarchy.
    "$wrapper" bt8bridge --help >output 2>&1
    rg -q 'builder-args: <--help>' output
    ! rg -q 'secrets:' output
    [ ! -e openwrt-images ]
    "$wrapper" bt8bridge -h >output 2>&1
    rg -q 'builder-args: <--help>' output
    ! rg -q 'secrets:' output
    [ ! -e openwrt-images ]
    OPENWRT_SECRETS_FILE=secrets.yaml "$wrapper" bt8bridge --no-secrets --help >output 2>&1
    rg -q 'builder-args: <--help>' output
    [ ! -e openwrt-images ]

    for option in config-file output-dir target subtarget profile release package authorized-key image-builder-tarball; do
      expect_failure 'fixed by the evaluated device manifest' "--$option" value
      expect_failure 'fixed by the evaluated device manifest' "--$option=value"
    done

    expect_failure 'unknown openwrt-build option' --config=value
    expect_failure 'unknown openwrt-build option' --config-f=value
    expect_failure 'unknown openwrt-build option' --out=value
    expect_failure 'no OpenWrt secrets file was found'

    expect_success --secrets-file secrets.yaml
    rg -q '<--secrets-file> <secrets.yaml>' output
    expect_success --secrets-file=secrets.yaml
    rg -q '<--secrets-file> <secrets.yaml>' output
    printf 'test-secret\n' | "$wrapper" bt8bridge --secrets-file - >output 2>&1
    rg -q 'stdin-secret:test-secret' output

    expect_success --cache-dir cache --no-secrets
    rg -q '<--cache-dir> <cache>' output
    expect_success --cache-dir=cache --no-secrets
    rg -q '<--cache-dir> <cache>' output

    expect_failure 'requires a non-empty' --secrets-file ""
    expect_failure 'requires a non-empty' --secrets-file=
    expect_failure 'requires a non-empty' --secrets-file secrets.yaml --secrets-file=
    expect_failure 'requires a non-empty' --secrets-file= --secrets-file secrets.yaml
    expect_failure 'cannot be combined' --no-secrets --secrets-file secrets.yaml
    expect_failure 'may only be specified once' --secrets-file first.yaml --secrets-file=second.yaml

    expect_success --no-secrets
    OPENWRT_SECRETS_FILE=secrets.yaml expect_success
    rg -q 'environment-secrets:secrets.yaml' output
    OPENWRT_SECRETS_FILE=secrets.yaml expect_failure 'cannot be combined' --no-secrets
    OPENWRT_SECRETS_FILE= expect_failure 'no OpenWrt secrets file was found'

    touch "$out"
  ''
