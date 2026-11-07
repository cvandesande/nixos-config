{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ../../modules/roles/workstation.nix
    # by-path (PCI slot), not by-id: by-id is the drive's serial and this repo is public. Disko is the only consumer -- re-run it after moving a drive.
    # This SATA bay also exposes an `ata-1.0` alias; both link to the same disk.
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-path/pci-0000:03:00.0-ata-1";
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

  # The greeter's kwin only shows the on-screen keyboard on touch/tablet hardware unless this is set (KDE bug 466948).
  systemd.user.services.plasma-login-kwin_wayland.environment.KWIN_IM_SHOW_ALWAYS = "1";

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
