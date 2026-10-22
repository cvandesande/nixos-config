{ pkgs, ... }:

{
  users.groups.plugdev = { };
  users.users.cvandesande = {
    isNormalUser = true;
    description = "Chris";
    extraGroups = [
      "dialout"
      "plugdev"
      "wheel"
    ];
  };

  # mount.nfs4 isn't setuid by default, so fstab entries marked "users" fail.
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
