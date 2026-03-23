{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "deployd-api";
  version = "0.1.0";

  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "HTTP API for deployd container deployment service";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "deployd-api";
  };
}
