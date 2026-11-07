{ pkgs, lib, ... }:

{
  users.users.cvandesande = {
    extraGroups = [
      "docker"
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

  # +C: no CoW, to avoid btrfs fragmentation. Created here so the flag applies.
  # The rootless store lives in the user's home, so it needs the same treatment.
  systemd.tmpfiles.rules = [
    "d /var/lib/docker 0711 root root -"
    "h /var/lib/docker - - - - +C"

    "d /home/cvandesande/.local/share/containers/storage 0700 cvandesande users -"
    "h /home/cvandesande/.local/share/containers/storage - - - - +C"

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

  systemd.services.libvirtd.wantedBy = lib.mkForce [ ];
}
