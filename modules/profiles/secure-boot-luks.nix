{ lib, pkgs, ... }:

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

  # Temporary validation for nixos/swapDevices.randomEncryption:
  # mkswap writes the swap signature after the dm-crypt mapper is created, but
  # udev sometimes keeps the mapper at SYSTEMD_READY=0. Re-trigger probing
  # before the generated .swap unit is allowed to start.
  systemd.services.mkswap-dev-disk-byx2dpartlabel-diskx2dmainx2dswap.serviceConfig.ExecStartPost =
    let
      mapperDevice = "/dev/mapper/dev-disk-byx2dpartlabel-diskx2dmainx2dswap";
    in
    [
      "${pkgs.systemd}/bin/udevadm trigger --action=change ${mapperDevice}"
      "${pkgs.systemd}/bin/udevadm settle"
    ];
}
