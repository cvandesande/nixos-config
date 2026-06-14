{
  config,
  pkgsUnstable,
  ...
}:

{
  hardware.enableRedistributableFirmware = true;

  boot = {
    supportedFilesystems = [ "zfs" ];
    zfs = {
      package = pkgsUnstable.zfs;
      forceImportRoot = false;
    };
  };

  environment.systemPackages = [
    config.boot.zfs.package
  ];

  networking.networkmanager.enable = true;

  users.users.cvandesande.extraGroups = [ "networkmanager" ];

  system.autoUpgrade = {
    enable = true;
    flake = "path:/home/cvandesande/nixos-config#${config.networking.hostName}";
    flags = [
      "--update-input"
      "nixpkgs"
      "--update-input"
      "nixpkgs-unstable"
    ];
    dates = "daily";
    randomizedDelaySec = "45min";
    allowReboot = false;
  };

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
