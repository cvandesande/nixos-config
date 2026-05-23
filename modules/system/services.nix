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
        enable = true;
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

    # YubiKey/FIDO2 support
    udev.packages = [
      pkgs.libfido2
      pkgs.yubikey-personalization
    ];
  };

  # Containers
  virtualisation.docker.enable = true;

  # Scanning
  hardware.sane = {
    enable = true;
    extraBackends = [ pkgs.epsonscan2 ];
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
