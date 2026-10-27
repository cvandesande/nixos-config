# spotifast release tarball from crmne/spotifast, taken from the
# spotifast-<system> flake inputs instead of the flake's from-source build.
{
  lib,
  stdenv,
  autoPatchelfHook,
  alsa-lib,
  pipewire,
  libGL,
  libxkbcommon,
  vulkan-loader,
  wayland,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
  src,
}:

stdenv.mkDerivation {
  pname = "spotifast";
  version = "release";
  inherit src;

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    alsa-lib
    pipewire
    stdenv.cc.cc.lib
  ];
  # Opened at runtime by the windowing/graphics stack, so not in the ELF NEEDED list.
  runtimeDependencies = [
    libGL
    libxkbcommon
    vulkan-loader
    wayland
    libx11
    libxcursor
    libxi
    libxrandr
  ];

  unpackPhase = "mkdir source && tar xzf $src -C source --strip-components=1";
  sourceRoot = "source";

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 spotifast $out/bin/spotifast
    install -Dm644 packaging/applications/spotifast.desktop $out/share/applications/spotifast.desktop
    install -Dm644 packaging/icons/spotifast.svg $out/share/icons/hicolor/scalable/apps/spotifast.svg
    runHook postInstall
  '';

  meta = {
    description = "Spotifast (release binary)";
    homepage = "https://github.com/crmne/spotifast";
    license = lib.licenses.mit;
    mainProgram = "spotifast";
  };
}
