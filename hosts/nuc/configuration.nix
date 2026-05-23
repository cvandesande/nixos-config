{ ... }:

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
        enable = true;
        configurationLimit = 10;
        editor = false;
      };

      efi.canTouchEfiVariables = true;
    };

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
