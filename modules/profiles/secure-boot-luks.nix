{ lib, ... }:

{
  boot = {
    loader = {
      timeout = 0;
      systemd-boot = {
        enable = lib.mkForce false;
        configurationLimit = lib.mkDefault 3;
        editor = false;
      };

      efi.canTouchEfiVariables = true;
    };

    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };

    initrd = {
      # Required for systemd-cryptenroll TPM2/FIDO2 LUKS unlock and Plymouth
      # passphrase prompts.
      systemd.enable = true;

      # These options are used only after matching LUKS2 token slots have been
      # enrolled with systemd-cryptenroll. The original passphrase remains a
      # fallback unless you explicitly remove that LUKS slot.
      luks.devices.crypted.crypttabExtraOpts = [
        "tpm2-device=auto"
        "fido2-device=auto"
      ];
    };

    plymouth.enable = true;

    consoleLogLevel = 3;
    initrd.verbose = false;
    kernelParams = [
      "quiet"
      "udev.log_level=3"
      "systemd.show_status=auto"
    ];
  };
}
