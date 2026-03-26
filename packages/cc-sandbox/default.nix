{
  lib,
  stdenv,
  makeWrapper,
  python3,
  skopeo,
  nix,
  cacert,
}: let
  python = python3.withPackages (ps: [ps.requests]);
  runtimeDeps = [
    python
    skopeo
    nix
    cacert
  ];
in
  stdenv.mkDerivation {
    pname = "cc-sandbox";
    version = "0.1.0";

    src = ./.;

    nativeBuildInputs = [makeWrapper];

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      mkdir -p $out/bin $out/share/cc-sandbox
      cp cc_sandbox.py $out/share/cc-sandbox/

      makeWrapper ${python}/bin/python3 $out/bin/cc-sandbox \
        --add-flags "$out/share/cc-sandbox/cc_sandbox.py" \
        --prefix PATH : ${lib.makeBinPath runtimeDeps} \
        --set SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"
    '';

    meta = {
      description = "Claude Code sandbox orchestrator — creates isolated coding environments via deployd";
      mainProgram = "cc-sandbox";
    };
  }
