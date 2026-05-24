{ lib, ... }:

{
  # Networking
  networking.networkmanager.enable = true;

  services = {
    # Remote access
    openssh.enable = lib.mkDefault true;

    # Desktop
    displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
      };

      autoLogin = {
        enable = false;
        user = "cvandesande";
      };
    };
    desktopManager.plasma6.enable = true;

    # Storage maintenance
    fstrim.enable = true;
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
