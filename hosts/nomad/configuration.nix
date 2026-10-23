{
  config,
  lib,
  inputs,
  ...
}:

{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-intel-core-ultra-series3
    ../../modules/roles/workstation.nix
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4f03f482";
      swapSize = "16G";
    })
  ];

  networking.hostName = "nomad";
  networking.hostId = "58d246a9";

  time.timeZone = "Europe/Dublin";
  system.stateVersion = "26.05";

  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false; # UsePAM defeats this
  };

  boot.kernelModules = [ "kvm-intel" ];

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  workstation.zfs.enable = false;
}
