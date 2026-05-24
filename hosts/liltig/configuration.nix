{ ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../../modules/system/applications.nix
    ../../modules/system/boot.nix
    ../../modules/system/hardware.nix
    ../../modules/system/nix-settings.nix
    ../../modules/system/services.nix
    ../../modules/system/users.nix
    ../../modules/system/virtualisation.nix
  ];

  networking.hostName = "liltig";

  time.timeZone = "Europe/Dublin";

  # Change this only after reading the NixOS release notes for the release
  # used when the machine was first installed.
  system.stateVersion = "25.11";
}
