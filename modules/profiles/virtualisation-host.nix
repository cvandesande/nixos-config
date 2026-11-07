{ pkgs, lib, ... }:

{
  users.users.cvandesande = {
    extraGroups = [
      "libvirtd"
    ];

    # Pinned so a lost /var/lib/nixos/auto-subuid-map cannot move the range out from under
    # files the rootless store owns through it; check /etc/subuid before reusing this line.
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

  # +C: no CoW, to avoid btrfs fragmentation. Mount options cannot do this per subvolume
  # (btrfs(5)), so the flag is the only way. It covers inodes created after it, never before.
  systemd.tmpfiles.rules = [
    "d /var/lib/containers/storage - - - - -"
    "h /var/lib/containers/storage - - - - +C"

    # Every level named: tmpfiles makes unmentioned intermediates root-owned and then
    # refuses the transition, leaving rootless podman unable to open a store.
    "d /home/cvandesande/.local/share/containers 0700 cvandesande users -"
    "d /home/cvandesande/.local/share/containers/storage 0700 cvandesande users -"
    "h /home/cvandesande/.local/share/containers/storage - - - - +C"

    "d /var/lib/libvirt/images 0711 root root -"
    "h /var/lib/libvirt/images - - - - +C"
  ];

  virtualisation = {
    podman = {
      enable = true;

      # /bin/docker is a symlink to podman, so docs and muscle memory keep working; no
      # buildx or compose plugin, and a bare `docker run` uses root's store, not the unit's.
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
