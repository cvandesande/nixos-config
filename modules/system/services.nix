{ lib, pkgs, ... }:

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

    # YubiKey/FIDO2 support
    udev.packages = [
      pkgs.libfido2
      pkgs.yubikey-personalization
    ];
  };

  # Containers
  virtualisation.docker.enable = true;

  # Hardware
  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          # Shows battery charge of connected devices on supported
          # Bluetooth adapters. Defaults to 'false'.
          Experimental = true;
          # When enabled other devices can connect faster to us, however
          # the tradeoff is increased power consumption. Defaults to
          # 'false'.
          FastConnectable = true;
        };
      };
    };
    sane = {
      enable = true;
      extraBackends = [ pkgs.epsonscan2 ];
    };
  };

  # Use gpg-agent as the SSH agent so SSH keys can live on a YubiKey.
  programs = {
    ssh.startAgent = false;

    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
      pinentryPackage = pkgs.pinentry-qt;
    };
  };
}
