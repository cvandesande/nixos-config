{
  lib,
  stdenv,
  fetchurl,
  dpkg,
}:

# Intel NPU userspace driver (level-zero driver + OpenVINO NPU compiler), taken from Intel's own
# ubuntu24.04 release tarball instead of nixpkgs.
#
# nixpkgs carries intel-npu-driver 1.28.0, which predates Panther Lake's NPU: the 2026.4 NF4 MoE
# exports only compile with 1.38.x, which is what every working run on nomad has used. Intel ships
# these as .debs only, so they are unpacked here rather than installed; the kernel part comes from
# the in-tree intel_vpu driver and firmware from nixos-hardware's firmware set.
#
# Both packages land in usr/lib/x86_64-linux-gnu; the tree is flattened to $out/lib so it can go on
# LD_LIBRARY_PATH whole, and ZE_ENABLE_ALT_DRIVERS points at the level-zero driver because the
# level-zero loader comes from nixpkgs and would not look in a store path on its own.
stdenv.mkDerivation (finalAttrs: {
  pname = "intel-npu-userspace";
  version = "1.38.0.20260910";

  src = fetchurl {
    url = "https://github.com/intel/linux-npu-driver/releases/download/v1.38.0/linux-npu-driver-v1.38.0.20260910-34487311128-ubuntu2404.tar.gz";
    hash = "sha256-HvzUtgwiq+51HY8nBZYsvMKlad5Fx+DmcM8Ir7/NwdI=";
  };

  nativeBuildInputs = [ dpkg ];
  dontConfigure = true;
  dontBuild = true;

  unpackPhase = ''
    runHook preUnpack
    mkdir -p deb && tar xf $src -C deb
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    for d in deb/intel-level-zero-npu_*.deb deb/intel-driver-compiler-npu_*.deb; do
      dpkg-deb -x "$d" unpacked
    done
    cp -a unpacked/usr/lib/x86_64-linux-gnu/. $out/lib/
    # Nothing here is a build-time link target, so a dangling dev symlink is only noise.
    find $out/lib -xtype l -delete
    runHook postInstall
  '';

  meta = {
    description = "Intel NPU level-zero driver and OpenVINO compiler plugin, unpacked from Intel's deb release";
    homepage = "https://github.com/intel/linux-npu-driver";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
})
