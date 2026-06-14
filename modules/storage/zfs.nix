{
  config,
  inputs,
  pkgs,
  ...
}:

let
  unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
  };
in
{
  boot = {
    supportedFilesystems = [ "zfs" ];
    zfs.package = unstable.zfs;
    zfs.forceImportRoot = false;
  };

  environment.systemPackages = [
    config.boot.zfs.package
  ];
}
