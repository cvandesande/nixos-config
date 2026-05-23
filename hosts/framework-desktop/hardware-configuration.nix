{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ ];

  # This is a placeholder so the flake evaluates before the first install.
  # During the install, run:
  #
  #   nixos-generate-config --root /mnt
  #   cp /mnt/etc/nixos/hardware-configuration.nix ./hosts/framework-desktop/hardware-configuration.nix
  #
  # Then inspect the generated file. If it contains fileSystems entries for
  # /, /home, /nix, /var/log, /.snapshots, or /boot that conflict with Disko,
  # remove those duplicate entries and let Disko own the mount layout.
}
