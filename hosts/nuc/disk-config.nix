# Replace this with the NUC's real whole-disk /dev/disk/by-id path before
# running Disko. Use a whole disk path, not a -partN partition path.
import ../../modules/disko/luks-btrfs.nix {
  device = "/dev/disk/by-id/REPLACE_WITH_NUC_DISK";
}
