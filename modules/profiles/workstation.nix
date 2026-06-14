{ ... }:

{
  hardware.enableRedistributableFirmware = true;

  networking.networkmanager.enable = true;

  users.users.cvandesande.extraGroups = [ "networkmanager" ];

  services = {
    fstrim.enable = false;

    btrfs.autoScrub = {
      enable = true;
      interval = "monthly";
      fileSystems = [ "/" ];
    };
    btrbk.instances.home = {
      onCalendar = "daily";
      settings = {
        timestamp_format = "long";
        snapshot_preserve = "7d";
        snapshot_preserve_min = "latest";

        volume."/home" = {
          snapshot_dir = "/.snapshots/home";
        };
      };
    };
  };
}
