{ pkgs, lib, ... }:

{
  users.users.cvandesande.extraGroups = [
    "docker"
    "libvirtd"
  ];

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  boot.binfmt.preferStaticEmulators = true;

  # Disable CoW on Docker/libvirt dirs to prevent btrfs fragmentation (dirs created here so +C applies).
  systemd.tmpfiles.rules = [
    "d /var/lib/docker 0711 root root -"
    "h /var/lib/docker - - - - +C"

    # Qemu disk images, via virt-manager's qemu:///system connection.
    "d /var/lib/libvirt/images 0711 root root -"
    "h /var/lib/libvirt/images - - - - +C"
  ];

  virtualisation = {
    docker = {
      enable = true;
      storageDriver = "btrfs";
    };

    podman.enable = true;

    libvirtd = {
      enable = true;
      extraOptions = [
        "--timeout"
        "0"
      ];
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = true;
        swtpm.enable = true;
      };
    };

    spiceUSBRedirection.enable = true;
  };

  # Don't start libvirtd by default
  systemd.services.libvirtd.wantedBy = lib.mkForce [ ];
}
