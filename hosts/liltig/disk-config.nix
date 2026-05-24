import ../../modules/storage/luks-btrfs.nix {
  device = "/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4086d232";
  swapSize = "128G";
}
