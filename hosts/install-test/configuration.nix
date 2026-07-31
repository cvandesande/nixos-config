{
  lib,
  modulesPath,
  ...
}:

# A cut-down workstation used only to exercise the install flow in a VM. It
# keeps the pieces that make the real install non-obvious -- Lanzaboote, the
# LUKS+btrfs Disko layout, and the systemd initrd -- and drops the desktop and
# dev toolchain so the closure stays small enough to build and boot quickly.
#
# This is not a host anyone installs on hardware.

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/vda";
      swapSize = "2G";
      espSize = "512M";
    })
  ];

  networking.hostName = "install-test";
  networking.hostId = "0badc0de";

  time.timeZone = "Europe/Dublin";

  # A fixed passphrase so the test can run unattended. The real hosts prompt.
  disko.devices.disk.main.content.partitions.luks.content.passwordFile = "/tmp/luks.key";

  boot = {
    initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
    ];

    # The image builder has no writable EFI variable store, so the bootloader
    # is installed into the ESP without registering a firmware boot entry.
    # Real installs run with canTouchEfiVariables = true.
    loader.efi.canTouchEfiVariables = lib.mkForce false;
  };

  users.users.cvandesande.initialPassword = "test";
  users.users.root.initialPassword = "test";
}
