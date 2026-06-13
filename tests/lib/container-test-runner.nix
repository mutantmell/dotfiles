{
  pkgs,
  lib,
}: args:
(import (pkgs.path + "/nixos/lib/testing/default.nix") {inherit lib;}).runTest (args
  // {
    imports = (args.imports or []) ++ [{hostPkgs = pkgs;}];
    node.pkgs = pkgs;
    containerDefaults = {config, ...}: {
      system.name = "m${toString config.virtualisation.test.nodeNumber}";
      networking.useHostResolvConf = false;
    };
    requiredFeatures = (args.requiredFeatures or {}) // {kvm = lib.mkForce false;};
  })
