{
  config,
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:

{
  options.workstation.zfs.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable ZFS kernel module and userspace tooling (default: on).";
  };

  config = {
    boot = {
      kernelPackages = lib.mkDefault pkgsUnstable.linuxPackages_xanmod_latest;

      supportedFilesystems = lib.mkIf config.workstation.zfs.enable [ "zfs" ];
      zfs = lib.mkIf config.workstation.zfs.enable {
        package = pkgsUnstable.zfs;
        forceImportRoot = false;
      };
    };

    hardware.enableRedistributableFirmware = true;

    environment.systemPackages = [
      pkgs.nvd
    ]
    ++ lib.optional config.workstation.zfs.enable config.boot.zfs.package;

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

    systemd.services.nixos-upgrade.onSuccess = [ "flake-lock-commit.service" ];

    systemd.services.flake-lock-commit = {
      description = "Commit updated flake.lock after a successful nixos-upgrade";
      path = [ pkgs.git ];
      serviceConfig = {
        Type = "oneshot";
        User = "cvandesande";
        WorkingDirectory = "/home/cvandesande/nixos-config";
      };
      script = ''
        if ! git diff --quiet -- flake.lock; then
          git add flake.lock
          git commit -m "flake.lock: automated update $(date -I)"
        fi
      '';
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

          # btrbk requires a subvolume entry; /.snapshots is @snapshots from luks-btrfs.nix.
          volume."/" = {
            subvolume."home" = {
              snapshot_dir = "/.snapshots";
            };
          };
        };
      };
    };
  };
}
