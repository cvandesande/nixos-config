{ lib, ... }:

{
  services.openssh.enable = lib.mkDefault true;

  networking.networkmanager.enable = true;

  # Weekly SSD/NVMe TRIM. This is enabled by default in current NixOS, but kept
  # explicit here because the disk layout intentionally uses LUKS + Btrfs.
  services.fstrim.enable = true;

  # Monthly Btrfs scrub. Scrub verifies checksums and is independent from TRIM.
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };
}
