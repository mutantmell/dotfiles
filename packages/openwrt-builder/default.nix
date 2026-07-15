{
  lib,
  stdenv,
  makeWrapper,
  python3,
  sops,
  gnumake,
  gnutar,
  coreutils,
  getopt,
  findutils,
  gnugrep,
  gawk,
  gnused,
  perl,
  patch,
  diffutils,
  file,
  unzip,
  bzip2,
  which,
  ncurses,
  rsync,
  wget,
  xz,
}: let
  # setuptools provides the distutils compatibility shim removed in Python 3.12,
  # which the OpenWrt imagebuilder's Makefile prerequisite check requires.
  python = python3.withPackages (ps: [ps.pyyaml ps.zstandard ps.setuptools]);
  runtimeDeps = [
    # python must be in PATH so the imagebuilder's own Makefile prereq checks
    # can find python3 when running `make image`.
    python
    sops
    gnumake
    gnutar
    coreutils
    getopt
    findutils
    gnugrep
    gawk
    gnused
    perl
    patch
    diffutils
    file
    unzip
    bzip2
    which
    ncurses
    rsync
    wget
    xz
  ];
in
  stdenv.mkDerivation {
    pname = "openwrt-builder";
    version = "0.1.0";

    src = ./.;

    nativeBuildInputs = [makeWrapper];

    dontConfigure = true;
    dontBuild = true;

    doCheck = true;
    checkPhase = ''
      ${python}/bin/python3 test_build.py
    '';

    installPhase = ''
      mkdir -p $out/bin $out/share/openwrt-builder
      cp build.py update-pins.py $out/share/openwrt-builder/

      makeWrapper ${python}/bin/python3 $out/bin/openwrt-build \
        --add-flags "$out/share/openwrt-builder/build.py" \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}

      makeWrapper ${python}/bin/python3 $out/bin/openwrt-update-pins \
        --add-flags "$out/share/openwrt-builder/update-pins.py" \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}
    '';

    meta = {
      description = "Generic OpenWrt image builder — provide device configs via --build-info";
      mainProgram = "openwrt-build";
    };
  }
