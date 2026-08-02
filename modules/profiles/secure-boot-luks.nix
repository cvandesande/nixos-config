{ lib, pkgs, ... }:

{
  boot = {
    loader = {
      timeout = 0;
      systemd-boot = {
        enable = lib.mkForce false;
        # Lanzaboote reads this option and passes it to `lzbt install`. Each
        # retained generation is a full unified kernel image on the ESP, so
        # this is bounded by espSize in modules/storage/luks-btrfs.nix.
        configurationLimit = lib.mkDefault 7;
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

      # TPM2/FIDO2 LUKS unlock (passphrase remains fallback unless slot removed).
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

  # Workaround: re-trigger udev probing so dm-crypt mapper is ready before the swap unit starts.
  systemd.services.mkswap-dev-disk-byx2dpartlabel-diskx2dmainx2dswap.serviceConfig.ExecStartPost =
    let
      mapperDevice = "/dev/mapper/dev-disk-byx2dpartlabel-diskx2dmainx2dswap";
    in
    [
      "${pkgs.systemd}/bin/udevadm trigger --action=change ${mapperDevice}"
      "${pkgs.systemd}/bin/udevadm settle"
    ];
}
