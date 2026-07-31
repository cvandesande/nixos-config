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
    description = ''
      Whether to enable ZFS kernel module and userspace tooling for this
      workstation host. Defaults to on; set to false per-host to opt out
      (e.g. when the host has no ZFS use case, or the pinned kernel is
      temporarily ahead of the ZFS release's supported kernel range).
    '';
  };

  config = {
    hardware.enableRedistributableFirmware = true;

    boot = lib.mkIf config.workstation.zfs.enable {
      supportedFilesystems = [ "zfs" ];
      zfs = {
        package = pkgsUnstable.zfs;
        forceImportRoot = false;
      };
    };

    environment.systemPackages = [
      pkgs.nvd
    ] ++ lib.optional config.workstation.zfs.enable config.boot.zfs.package;

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

          # btrbk needs a subvolume section; a bare volume section snapshots
          # nothing ("No subvolume configured"). /home is the @home subvolume,
          # so address it as a subvolume of the / volume. snapshot_dir is
          # relative to the volume directory, and /.snapshots is the @snapshots
          # subvolume created by modules/storage/luks-btrfs.nix.
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
