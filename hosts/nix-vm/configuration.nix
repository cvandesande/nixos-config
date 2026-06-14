{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    (import ../../modules/storage/ext4-simple.nix {
      device = "/dev/vda";
    })
  ];

  networking.hostName = "nix-vm";
  networking.hostId = "c6d8f31a";

  boot = {
    initrd = {
      availableKernelModules = [ "virtio_pci" ];
      kernelModules = [ ];
    };
    kernelModules = [ ];
    extraModulePackages = [ ];
  };
}
