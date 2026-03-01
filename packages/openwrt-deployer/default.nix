{ lib, stdenv, makeWrapper, openssh, coreutils }:

stdenv.mkDerivation {
  pname = "openwrt-deployer";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin
    cp deploy.sh $out/bin/openwrt-deploy
    chmod +x $out/bin/openwrt-deploy

    wrapProgram $out/bin/openwrt-deploy \
      --prefix PATH : ${lib.makeBinPath [ openssh coreutils ]}
  '';

  meta = {
    description = "Deploy OpenWrt sysupgrade images to devices via SSH";
    mainProgram = "openwrt-deploy";
  };
}
