{
  lib,
  pkgs,
  config,
  openwrtLib,
  owrtData,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.openwrt;

  uciConfigType = types.attrsOf (types.attrsOf (types.attrsOf types.anything));

  collectSecrets = path: value:
    if builtins.isAttrs value && value ? _secret
    then {"${value._secret}" = [path];}
    else if builtins.isAttrs value
    then
      lib.foldlAttrs
      (
        acc: key: child:
          if key == "_type" || key == "_anonymous"
          then acc
          else let
            childPath =
              if path == ""
              then key
              else "${path}.${key}";
            found = collectSecrets childPath child;
          in
            lib.foldlAttrs
            (acc2: k: v: acc2 // {"${k}" = (acc2.${k} or []) ++ v;})
            acc
            found
      )
      {}
      value
    else {};

  renderedConfig = lib.recursiveUpdate cfg.uci.generatedConfig cfg.uci.extraConfig;
  secretsMap = collectSecrets "" renderedConfig;
  uciScript = openwrtLib.uci.mkUCIDefaults {
    name = "nix-config";
    config = renderedConfig;
    preCommands = cfg.uci.preCommands;
  };
  uciFile = builtins.toFile "uci-defaults-${cfg.hostname}.sh" uciScript;
  keysFile = builtins.toFile "authorized-keys" (lib.concatStringsSep "\n" (cfg.authorizedKeys ++ [""]));
  # Stable identity for the evaluated, non-secret image inputs. Secret-bearing
  # artifacts are additionally pinned by their SHA-256 at deployment time.
  buildId = builtins.hashString "sha256" (builtins.toJSON {
    inherit (cfg) hostname;
    inherit (cfg.image) profile target subtarget release;
    deviceType = cfg.device.role;
    packages = cfg.packages.final;
    inherit (cfg.uci) radiosToEnable;
    inherit renderedConfig;
    preCommands = cfg.uci.preCommands;
    inherit (cfg) authorizedKeys;
    imageBuilder =
      if cfg.image.builderTarball == null
      then null
      else builtins.unsafeDiscardStringContext (toString cfg.image.builderTarball);
    extraFiles = lib.mapAttrs (_: path: builtins.hashFile "sha256" path) cfg.extraFiles;
  });
  manifest =
    {
      inherit (cfg) hostname;
      inherit buildId;
      inherit (cfg.image) profile target subtarget release;
      deviceType = cfg.device.role;
      packages = cfg.packages.final;
      inherit secretsMap;
      inherit (cfg.uci) radiosToEnable;
      uciDefaults = "${uciFile}";
      authorizedKeys = "${keysFile}";
      extraFiles = lib.mapAttrs (_: toString) cfg.extraFiles;
    }
    // lib.optionalAttrs (cfg.image.builderTarball != null) {
      imageBuilderTarball = "${cfg.image.builderTarball}";
    };
in {
  options.openwrt = {
    hostname = mkOption {
      type = types.str;
      description = "OpenWrt device hostname.";
    };

    image = {
      profile = mkOption {
        type = types.str;
        apply = profile:
          if lib.hasPrefix "asus_zenwifi-bt8" profile && lib.hasInfix "ubootmod" profile
          then throw "OpenWrt BT8 profile must preserve the stock ASUS bootloader layout"
          else profile;
        description = "OpenWrt Image Builder profile.";
      };
      target = mkOption {
        type = types.str;
        description = "OpenWrt target.";
      };
      subtarget = mkOption {
        type = types.str;
        description = "OpenWrt subtarget.";
      };
      release = mkOption {
        type = types.str;
        default = owrtData.defaultRelease;
        description = "OpenWrt release.";
      };
      builderTarball = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Pinned Image Builder tarball derivation/path.";
      };
    };

    device = {
      role = mkOption {
        type = types.str;
        description = "Human-readable device role used by tooling.";
      };
      hostId = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Host ID used with shared OpenWrt addressing helpers.";
      };
    };

    locale = {
      timezone = mkOption {
        type = types.str;
        default = owrtData.defaultTimezone;
      };
      country = mkOption {
        type = types.str;
        default = owrtData.defaultCountry;
      };
    };

    authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = owrtData.authorizedKeys;
      description = "SSH authorized keys baked into the image overlay.";
    };

    extraFiles = mkOption {
      type = types.attrsOf types.path;
      default = {};
      description = "Additional non-secret declarative files to bake into the image, keyed by absolute target path.";
    };

    packages = {
      base = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Profile-provided OpenWrt packages.";
      };
      extra = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Device-specific OpenWrt package additions/removals.";
      };
      final = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = "Final package list passed to Image Builder.";
      };
    };

    uci = {
      generatedConfig = mkOption {
        type = uciConfigType;
        default = {};
        description = "Profile-generated UCI configuration.";
      };
      extraConfig = mkOption {
        type = uciConfigType;
        default = {};
        description = "Device-specific UCI configuration overlay.";
      };
      finalConfig = mkOption {
        type = uciConfigType;
        readOnly = true;
        description = "Final rendered UCI configuration.";
      };
      preCommands = mkOption {
        type = types.listOf types.str;
        default = openwrtLib.migrationPreCommands;
        description = "Shell commands emitted before UCI commands.";
      };
      secretsMap = mkOption {
        type = types.attrsOf (types.listOf types.str);
        readOnly = true;
        description = "Map of flattened secret keys to UCI paths.";
      };
      radiosToEnable = mkOption {
        type = types.listOf types.str;
        default = ["radio0" "radio1"];
        description = "Wireless UCI device sections enabled only after all required secrets are injected.";
      };
    };

    build = {
      manifest = mkOption {
        type = types.attrsOf types.anything;
        readOnly = true;
        description = "Canonical build manifest consumed by openwrt-builder.";
      };
      configDir = mkOption {
        type = types.package;
        readOnly = true;
        description = "Derivation containing build.json for this OpenWrt device.";
      };
    };

    deviceInfo = mkOption {
      type = types.attrsOf types.anything;
      readOnly = true;
      description = "Metadata used by management apps.";
    };
  };

  config.openwrt = {
    packages.final = cfg.packages.base ++ cfg.packages.extra;
    uci.finalConfig = renderedConfig;
    uci.secretsMap = secretsMap;
    build.manifest = manifest;
    build.configDir = pkgs.runCommand "openwrt-config-${cfg.hostname}" {} ''
      mkdir -p $out
      cat > $out/build.json <<'EOF'
      ${builtins.toJSON manifest}
      EOF
    '';
    deviceInfo = {
      inherit (cfg) hostname;
      inherit (cfg.image) profile target subtarget release;
      inherit (cfg.device) role;
      packages = cfg.packages.final;
    };
  };
}
