{
  config,
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:

{
  imports = [
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-id/wwn-0x5002538900035614";
      swapSize = "16G";
    })
  ];

  networking.hostName = "nuc";
  networking.hostId = "d95c8e8b";

  time.timeZone = "Europe/Dublin";

  boot = {
    kernelPackages = pkgsUnstable.linuxPackages_xanmod_latest;

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

    # Removes error from unused hardware on NUC
    blacklistedKernelModules = [ "spi_nor" ];

    # Work around this NUC firmware exposing the TPM2 CRB command buffer in a
    # region Linux otherwise treats as busy:
    # tpm_crb MSFT0101:00: error -EBUSY ... [mem 0xa2fff000-0xa2fff02f]
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

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "i965";
  };

  programs = {
    # This NUC has only USB-A ports, so use OpenSSH's agent for KeePassXC
    # instead of gpg-agent's YubiKey-oriented SSH support.
    ssh.startAgent = true;
    gnupg.agent.enableSSHSupport = false;
  };

  services.thermald.enable = true;
}
