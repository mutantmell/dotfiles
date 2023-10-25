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
    hash = "sha256-KxYxHNoXk4RVA5+mpE3hjrl1c+7Ei/km/zrMIvvV+1M=";
  };

  postPatch = ''
    patchShebangs --build src/configure
  '';

  nativeBuildInputs = [
    installShellFiles
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -R bin "$out/bin"
    cp -R libexec "$out/libexec"
    #cp -R plugins "$out/plugins"

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
