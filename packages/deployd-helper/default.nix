{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "deployd-helper";
  version = "0.1.0";

  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Privileged helper for deployd container deployment service";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "deployd-helper";
  };
}
