# rtk-oss release binary from rtk-ai/rtk, taken from the rtk-<system> flake
# inputs instead of building from source.
{
  lib,
  stdenv,
  autoPatchelfHook,
  src,
}:

stdenv.mkDerivation {
  pname = "rtk";
  version = "release";
  inherit src;

  # The x86_64 build is static musl; the aarch64 build is dynamically linked.
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  unpackPhase = "mkdir source && tar xzf $src -C source";
  sourceRoot = "source";

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 rtk $out/bin/rtk
    runHook postInstall
  '';

  meta = {
    description = "CLI proxy that reduces LLM token usage (release binary)";
    homepage = "https://github.com/rtk-ai/rtk";
    license = lib.licenses.unfree;
    mainProgram = "rtk";
  };
}
