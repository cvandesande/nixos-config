{ lib, pkgs, ... }:

{
  boot = {
    loader = {
      timeout = 0;
      systemd-boot = {
        enable = lib.mkForce false;
        configurationLimit = lib.mkDefault 7; # full UKIs on the ESP (espSize in luks-btrfs.nix)
        editor = false;
      };

      efi.canTouchEfiVariables = true;
    };

    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };

    initrd = {
      systemd.enable = true;

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

  # Workaround: re-probe the mapper device so it exists before the swap unit starts.
  systemd.services.mkswap-dev-disk-byx2dpartlabel-diskx2dmainx2dswap.serviceConfig.ExecStartPost =
    let
      mapperDevice = "/dev/mapper/dev-disk-byx2dpartlabel-diskx2dmainx2dswap";
    in
    [
      "${pkgs.systemd}/bin/udevadm trigger --action=change ${mapperDevice}"
      "${pkgs.systemd}/bin/udevadm settle"
    ];
}
