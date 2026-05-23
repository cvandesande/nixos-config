# Replace this with the NUC's real whole-disk /dev/disk/by-id path before
# running Disko. Use a whole disk path, not a -partN partition path.
import ../../modules/disko/luks-btrfs.nix {
  device = "/dev/disk/by-id/wwn-0x5002538900035614";
}
