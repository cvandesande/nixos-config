{ pkgs, ... }:

let
  mapperDevice = "/dev/mapper/dev-disk-byx2dpartlabel-diskx2dmainx2dswap";
in
{
  # Temporary validation for nixos/swapDevices.randomEncryption:
  # mkswap writes the swap signature after the dm-crypt mapper is created, but
  # udev sometimes keeps the mapper at SYSTEMD_READY=0. Re-trigger probing
  # before the generated .swap unit is allowed to start.
  systemd.services.mkswap-dev-disk-byx2dpartlabel-diskx2dmainx2dswap.serviceConfig.ExecStartPost = [
    "${pkgs.systemd}/bin/udevadm trigger --action=change ${mapperDevice}"
    "${pkgs.systemd}/bin/udevadm settle"
  ];
}
