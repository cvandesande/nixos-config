{ lib, pkgs, ... }:

{
  # One kernel for every host, from the stable channel; Xanmod is x86_64-only (broken elsewhere in nixpkgs), so non-x86 hosts must override.
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_xanmod_latest;
}
