{ lib
, stdenv
, fetchFromGitHub
, installShellFiles
}:

stdenv.mkDerivation rec {
  pname = "jenv";
  version = "0.5.6";

  src = fetchFromGitHub {
    owner = "jenv";
    repo = "jenv";
    rev = "refs/tags/${version}";
    hash = "sha256-2N8LONZvu7n6hRi6+Dt5V9F9CerphSFbMBG58WIBWDI=";
    fetchSubmodules = true;
  };

  dontConfigure = true;

  nativeBuildInputs = [
    installShellFiles
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -R bin "$out/bin"
    cp -R libexec "$out/libexec"

    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion completions/jenv.{bash,fish,zsh}
  '';

  meta = with lib; {
    description = "Manage your Java environment";
    homepage = "https://www.jenv.be/";
    license = licenses.mit;
    platforms = platforms.all;
    mainProgram = "jenv";
  };
}
