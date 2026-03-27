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

      # CLI wrapper: has nix + skopeo in PATH for `rebuild-image`
      makeWrapper ${python}/bin/python3 $out/bin/cc-sandbox \
        --add-flags "$out/share/cc-sandbox/cc_sandbox.py" \
        --prefix PATH : ${lib.makeBinPath [python skopeo nix cacert]} \
        --set SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"

      # Daemon wrapper: restricted PATH — only python (no nix, skopeo, SSH)
      makeWrapper ${python}/bin/python3 $out/bin/cc-sandbox-daemon \
        --add-flags "$out/share/cc-sandbox/cc_sandbox.py" \
        --add-flags "daemon" \
        --prefix PATH : ${lib.makeBinPath [python cacert]} \
        --set SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"
    '';

    meta = {
      description = "Claude Code sandbox orchestrator — creates isolated coding environments via deployd";
      mainProgram = "cc-sandbox";
    };
  }
