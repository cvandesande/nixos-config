{
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:

{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ ];

  environment = {
    systemPackages = with pkgs; [
      # Desktop applications
      pkgsUnstable.discord
      epsonscan2
      gajim
      pkgsUnstable.keepassxc
      pkgsUnstable.nextcloud-client
      pkgsUnstable.obsidian
      onlyoffice-desktopeditors
      signal-desktop
      pkgsUnstable.stremio-linux-shell

      # Hardware tools
      libva-utils
      pciutils
      vulkan-tools

      # KDE specific
      papirus-icon-theme
      kdePackages.isoimagewriter
      kdePackages.partitionmanager
      hardinfo2
      vlc

      # Filesystem, encryption, and install support
      btrfs-progs
      compsize
      cryptsetup
      sbctl
      tpm2-tools

      # YubiKey, FIDO2, and GPG/SSH-agent support
      libfido2
      pinentry-qt
      kdePackages.ksshaskpass
      yubikey-manager
      yubikey-personalization
    ];

    sessionVariables = {
      SSH_ASKPASS_REQUIRE = "force";
    };
  };

  programs = {
    firefox.enable = true;
    thunderbird.enable = true;
    virt-manager.enable = true;
    zoom-us = {
      enable = true;
      package = pkgsUnstable.zoom-us;
    };

    # Enable generic/static compiled binaries to run
    nix-ld = {
      enable = true;
      libraries = with pkgs; [
        stdenv.cc.cc
      ];
    };

    dconf.profiles.user.databases = [
      {
        locks = [
          "/org/virt-manager/virt-manager/connections/autoconnect"
          "/org/virt-manager/virt-manager/connections/uris"
        ];
        settings."org/virt-manager/virt-manager/connections" = {
          autoconnect = [ "qemu:///system" ];
          uris = [ "qemu:///system" ];
        };
      }
    ];

    # FIDO2 Key support
    ssh = {
      startAgent = lib.mkDefault true;
      enableAskPassword = true;
      askPassword = "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";
    };

    gnupg.agent = {
      enable = true;
      enableSSHSupport = lib.mkDefault false;
      pinentryPackage = pkgs.pinentry-qt;
    };
  };
}
