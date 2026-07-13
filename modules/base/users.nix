{ pkgs, ... }:

{
  users.groups.plugdev = { };
  users.users.cvandesande = {
    isNormalUser = true;
    description = "Chris";
    extraGroups = [
      "plugdev"
      "wheel"
    ];
  };

  # Allow non-root users to mount and unmount NFS filesystems explicitly marked
  # "user" or "users" in fstab. The generic commands enforce the fstab policy;
  # the NFS-specific helpers need privilege to perform the actual operations.
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
