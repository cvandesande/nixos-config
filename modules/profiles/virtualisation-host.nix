{ pkgs, ... }:

{
  users.users.cvandesande.extraGroups = [
    "docker"
    "libvirtd"
  ];

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  boot.binfmt.preferStaticEmulators = true;

  systemd.tmpfiles.rules = [
    "d /var/lib/docker 0711 root root -"
    "h /var/lib/docker - - - - +C"
  ];

  virtualisation = {
    docker = {
      enable = true;
      storageDriver = "btrfs";
      daemon.settings = {
        features.containerd-snapshotter = true;
      };
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
