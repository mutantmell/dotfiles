{
  lib,
  stdenv,
  makeWrapper,
  openssh,
  coreutils,
  jq,
}:
stdenv.mkDerivation {
  pname = "openwrt-deployer";
  version = "0.2.0";

  src = ./.;

  nativeBuildInputs = [makeWrapper];
  nativeCheckInputs = [jq];

  dontConfigure = true;
  dontBuild = true;

  doCheck = true;
  checkPhase = ''
    patchShebangs test-deploy.sh deploy.sh
    DEPLOY=$PWD/deploy.sh ./test-deploy.sh
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp deploy.sh $out/bin/openwrt-deploy
    chmod +x $out/bin/openwrt-deploy

    wrapProgram $out/bin/openwrt-deploy \
      --prefix PATH : ${lib.makeBinPath [openssh coreutils jq]}
  '';

  meta = {
    description = "Deploy OpenWrt sysupgrade images to devices via SSH";
    mainProgram = "openwrt-deploy";
  };
}
