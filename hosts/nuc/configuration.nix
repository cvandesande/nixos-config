{ lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../../modules/system/nix-settings.nix
    ../../modules/system/packages.nix
    ../../modules/system/services.nix
    ../../modules/system/users.nix
  ];

  networking.hostName = "nuc";

  time.timeZone = "Europe/Dublin";

  boot = {
    loader = {
      systemd-boot = {
        enable = lib.mkForce false;
        configurationLimit = 2;
        editor = false;
      };

      efi.canTouchEfiVariables = true;
    };

    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };

    kernelPackages = pkgs.linuxPackages_latest;

    # Work around this NUC firmware exposing the TPM2 CRB command buffer in a
    # region Linux otherwise treats as busy:
    # tpm_crb MSFT0101:00: error -EBUSY ... [mem 0xa2fff000-0xa2fff02f]
    kernelParams = [
      "memmap=0x1000%0xa2fff000+2"
    ];

    initrd = {
      # Required for systemd-cryptenroll TPM2/FIDO2 LUKS unlock.
      systemd.enable = true;

      # These options are used only after matching LUKS2 token slots have been
      # enrolled with systemd-cryptenroll. The original passphrase remains a
      # fallback unless you explicitly remove that LUKS slot.
      luks.devices.crypted.crypttabExtraOpts = [
        "tpm2-device=auto"
        "fido2-device=auto"
      ];
    };
  };

  # Change this only after reading the NixOS release notes for the release
  # used when the machine was first installed.
  system.stateVersion = "25.11";
}
