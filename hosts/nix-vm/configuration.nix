{
  lib,
  modulesPath,
  pkgs,
  ...
}:

{
  imports = [
    ../../modules/roles/development-vm.nix
    (modulesPath + "/profiles/qemu-guest.nix")
    (import ../../modules/storage/ext4-simple.nix {
      device = "/dev/vda";
    })
  ];

  networking = {
    hostName = "nix-vm";
    hostId = "c6d8f31a";
    networkmanager.enable = false;
    useDHCP = false;
    useNetworkd = true;
  };

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
  system.stateVersion = "26.05";

  boot = {
    # Standard NixOS kernel (LTS) instead of the Xanmod default from modules/base.
    kernelPackages = pkgs.linuxPackages;

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

}
