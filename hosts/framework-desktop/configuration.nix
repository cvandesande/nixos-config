{ ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../../modules/system/nix-settings.nix
    ../../modules/system/packages.nix
    ../../modules/system/services.nix
    ../../modules/system/users.nix
  ];

  networking.hostName = "framework-desktop";

  time.timeZone = "Europe/Dublin";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Required for TPM2-based LUKS unlock later.
  # Keep password unlock working first; add TPM enrollment only after the base install boots.
  boot.initrd.systemd.enable = true;

  # Change this only after reading the NixOS release notes for the release
  # used when the machine was first installed.
  system.stateVersion = "26.05";
}
