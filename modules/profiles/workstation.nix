{
  config,
  pkgs,
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
    pkgs.nvd
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

  system.activationScripts.diffGens = ''
    (
      PATH=$PATH:${pkgs.nix}/bin
      {
        echo "===== $(date -Iseconds) ====="
        ${pkgs.nvd}/bin/nvd diff /run/current-system "$systemConfig"
        echo
      } | tee -a /var/log/nixos-upgrades.log
    )
  '';

  services = {
    fstrim.enable = false;

    logrotate.settings."/var/log/nixos-upgrades.log" = {
      frequency = "weekly";
      rotate = 8;
      compress = true;
      missingok = true;
      notifempty = true;
    };

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
