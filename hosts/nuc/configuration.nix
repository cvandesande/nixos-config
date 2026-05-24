{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./hardware.nix

    ../../modules/system/boot.nix
    ../../modules/system/nix-settings.nix
    ../../modules/system/packages.nix
    ../../modules/system/services.nix
    ../../modules/system/users.nix
  ];

  networking.hostName = "nuc";

  time.timeZone = "Europe/Dublin";

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;

    # Work around this NUC firmware exposing the TPM2 CRB command buffer in a
    # region Linux otherwise treats as busy:
    # tpm_crb MSFT0101:00: error -EBUSY ... [mem 0xa2fff000-0xa2fff02f]
    kernelParams = [
      "memmap=0x1000%0xa2fff000+2"
    ];
  };

  # Change this only after reading the NixOS release notes for the release
  # used when the machine was first installed.
  system.stateVersion = "25.11";
}
