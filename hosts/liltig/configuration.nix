{ ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../../modules/base/nix-settings.nix
    ../../modules/base/remote-access.nix
    ../../modules/base/users.nix
    ../../modules/profiles/applications.nix
    ../../modules/profiles/desktop.nix
    ../../modules/profiles/dev-toolchain.nix
    ../../modules/profiles/secure-boot-luks.nix
    ../../modules/profiles/virtualisation-host.nix
    ../../modules/profiles/workstation.nix
  ];

  networking.hostName = "liltig";

  time.timeZone = "Europe/Dublin";

  # Change this only after reading the NixOS release notes for the release
  # used when the machine was first installed.
  system.stateVersion = "25.11";
}
