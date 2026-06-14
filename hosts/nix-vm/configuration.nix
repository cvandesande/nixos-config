{
  lib,
  modulesPath,
  pkgsUnstable,
  ...
}:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    (import ../../modules/storage/ext4-simple.nix {
      device = "/dev/vda";
    })
  ];

  networking.hostName = "nix-vm";
  networking.hostId = "c6d8f31a";
  networking.networkmanager.enable = false;
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network = {
    enable = true;
    networks."10-dhcp" = {
      matchConfig.Name = [
        "en*"
        "eth*"
      ];
      networkConfig.DHCP = "yes";
    };
  };

  time.timeZone = "Europe/Dublin";

  boot = {
    kernelPackages = pkgsUnstable.linuxPackages_latest;

    loader = {
      timeout = 3;
      systemd-boot = {
        enable = true;
        configurationLimit = lib.mkDefault 3;
        editor = false;
      };
      efi.canTouchEfiVariables = true;
    };

    consoleLogLevel = 4;

    initrd = {
      systemd.enable = true;
      availableKernelModules = [ "virtio_pci" ];
      kernelModules = [ ];
    };
    kernelModules = [ ];
    extraModulePackages = [ ];
  };

  services = {
    displayManager.sddm.enable = lib.mkForce false;
    desktopManager.plasma6.enable = lib.mkForce false;
  };
}
