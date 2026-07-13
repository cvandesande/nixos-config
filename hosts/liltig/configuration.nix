{ pkgsUnstable, ... }:

{
  imports = [
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4086d232";
      swapSize = "128G";
    })
  ];

  networking.hostName = "liltig";
  networking.hostId = "534d981c";

  time.timeZone = "Europe/Dublin";

  boot.kernelPackages = pkgsUnstable.linuxPackages_xanmod_latest;

  # ZFS support is enabled globally by default in modules/profiles/workstation.nix
  # (used by both nuc and liltig). This host has no local ZFS pools (storage is
  # LUKS+btrfs) and doesn't need it, so opt out here.
  workstation.zfs.enable = false;
}
