{ pkgs, ... }:

{
  users.groups.plugdev = { };
  users.users.cvandesande = {
    isNormalUser = true;
    description = "Chris";
    extraGroups = [
      # USB serial adapters, for tio and friends.
      "dialout"
      "plugdev"
      "wheel"
    ];
  };

  # Allow non-root NFS mount/unmount for fstab entries marked "users".
  security.wrappers."mount.nfs4" = {
    source = "${pkgs.nfs-utils}/bin/mount.nfs4";
    owner = "root";
    group = "root";
    setuid = true;
  };
  security.wrappers."umount.nfs4" = {
    source = "${pkgs.nfs-utils}/bin/umount.nfs4";
    owner = "root";
    group = "root";
    setuid = true;
  };
}
