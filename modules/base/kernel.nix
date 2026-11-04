{ lib, pkgs, ... }:

{
  # One kernel for every host, from the stable channel. Xanmod is x86_64-only
  # (nixpkgs marks it broken elsewhere), so non-x86 hosts must override this.
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_xanmod_latest;
}
