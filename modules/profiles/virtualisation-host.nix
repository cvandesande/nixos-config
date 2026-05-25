{ pkgs, ... }:

{
  users.users.cvandesande.extraGroups = [
    "docker"
    "libvirtd"
  ];

  virtualisation = {
    docker = {
      enable = true;
      storageDriver = "btrfs";
    };

    libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = true;
        swtpm.enable = true;
      };
    };

    spiceUSBRedirection.enable = true;
  };
}
