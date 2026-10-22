{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ../../modules/roles/workstation.nix
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-id/wwn-0x5002538900035614";
      swapSize = "16G";
    })
  ];

  networking.hostName = "nuc";
  networking.hostId = "d95c8e8b";

  time.timeZone = "Europe/Dublin";
  system.stateVersion = "26.05";

  boot = {
    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "ahci"
        "usb_storage"
        "usbhid"
        "sd_mod"
      ];
      kernelModules = [ "i915" ];
    };

    kernelModules = [
      "kvm-intel"
      "nct6775"
    ];
    extraModulePackages = [ ];

    # Unused here, and it logs a probe error at boot.
    blacklistedKernelModules = [ "spi_nor" ];

    # Firmware reports the TPM2 CRB window busy (tpm_crb MSFT0101:00: error -EBUSY).
    kernelParams = [
      "acpi_enforce_resources=lax"
      "memmap=0x1000%0xa2fff000+2"
    ];
  };

  hardware = {
    cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

    graphics.extraPackages = with pkgs; [
      intel-vaapi-driver
      libvdpau-va-gl
    ];
  };

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "i965";
  };

  services.thermald.enable = true;

  workstation.zfs.enable = false;

  fileSystems."/home/cvandesande/mnt/whiterock" = {
    device = "whiterock:/zfspool/Downloads";
    fsType = "nfs4";
    options = [
      "defaults"
      "noauto"
      "noatime"
      "users"
      "bg"
      "x-systemd.mkdir"
    ];
  };
}
