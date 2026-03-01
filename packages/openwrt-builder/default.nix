{ lib, stdenv, makeWrapper, python3, sops, gnumake, gnutar, coreutils
, findutils, gnugrep, gawk, gnused, perl, patch, diffutils, file, unzip, bzip2
, which, ncurses, rsync, xz
}:

let
  python = python3.withPackages (ps: [ ps.pyyaml ps.zstandard ]);
  runtimeDeps = [
    sops gnumake gnutar coreutils findutils gnugrep gawk gnused
    perl patch diffutils file unzip bzip2 which ncurses rsync xz
  ];
in
stdenv.mkDerivation {
  pname = "openwrt-builder";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin $out/share/openwrt-builder
    cp build.py $out/share/openwrt-builder/

    makeWrapper ${python}/bin/python3 $out/bin/openwrt-build \
      --add-flags "$out/share/openwrt-builder/build.py" \
      --prefix PATH : ${lib.makeBinPath runtimeDeps}
  '';

  meta = {
    description = "Generic OpenWrt image builder — provide device configs via --build-info";
    mainProgram = "openwrt-build";
  };
}
