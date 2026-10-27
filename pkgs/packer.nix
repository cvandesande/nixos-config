# HashiCorp's official release binary (a static Go binary), taken from the
# packer-<system> flake inputs. nixpkgs builds packer from source because it is
# BSL-licensed (unfree, so not in cache.nixos.org).
{
  stdenvNoCC,
  unzip,
  src,
}:

stdenvNoCC.mkDerivation {
  pname = "packer";
  version = "release";
  inherit src;

  nativeBuildInputs = [ unzip ];
  unpackPhase = "unzip $src";
  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 packer $out/bin/packer
    runHook postInstall
  '';

  meta = {
    description = "Tool for creating machine images (official release binary)";
    homepage = "https://www.packer.io";
    mainProgram = "packer";
  };
}
