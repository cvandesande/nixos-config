{ pkgs, lib, ... }:

{
  users.users.cvandesande = {
    extraGroups = [
      "libvirtd"
    ];

    # Pinned so a lost /var/lib/nixos/auto-subuid-map cannot move the range out from under the rootless store's files; check /etc/subuid before reusing.
    subUidRanges = [
      {
        startUid = 100000;
        count = 65536;
      }
    ];
    subGidRanges = [
      {
        startGid = 100000;
        count = 65536;
      }
    ];
  };

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  boot.binfmt.preferStaticEmulators = true;

  # chattr/lsattr: +C is the only way to set and read NOCOW on a shared btrfs (btrfs(5)).
  environment.systemPackages = [ pkgs.e2fsprogs ];

  # +C: no CoW, to avoid btrfs fragmentation. Mount options cannot do this per subvolume (btrfs(5)), and it covers only inodes created after it.
  systemd.tmpfiles.rules = [
    "d /var/lib/containers/storage - - - - -"
    "h /var/lib/containers/storage - - - - +C"

    # Every level named: tmpfiles makes unmentioned intermediates root-owned and then refuses the transition, stranding rootless podman.
    "d /home/cvandesande/.local/share/containers 0700 cvandesande users -"
    "d /home/cvandesande/.local/share/containers/storage 0700 cvandesande users -"
    "h /home/cvandesande/.local/share/containers/storage - - - - +C"

    "d /var/lib/libvirt/images 0711 root root -"
    "h /var/lib/libvirt/images - - - - +C"
  ];

  virtualisation = {
    podman = {
      enable = true;

      # /bin/docker symlinks to podman for docs and muscle memory; no buildx or compose, and a bare `docker run` uses root's store, not the unit's.
      dockerCompat = true;
    };

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

  systemd.services.libvirtd.wantedBy = lib.mkForce [ ];
}
