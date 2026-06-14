{
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:

{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ ];

  environment.systemPackages = with pkgs; [
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
    yubikey-manager
    yubikey-personalization
  ];

  programs = {
    firefox = {
      enable = true;
      package = pkgsUnstable.firefox;
      preferences = {
        "widget.use-xdg-desktop-portal.file-picker" = 1;
      };
    };
    thunderbird.enable = true;
    virt-manager.enable = true;
    zoom-us = {
      enable = true;
      package = pkgsUnstable.zoom-us;
    };

    # Zed downloads language servers such as rust-analyzer as generic Linux
    # binaries, which expect the standard dynamic loader path to exist.
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

    # Use gpg-agent as the default SSH agent so SSH keys can live on a YubiKey.
    # Hosts can override this when they need a different agent backend.
    ssh.startAgent = lib.mkDefault false;

    gnupg.agent = {
      enable = true;
      enableSSHSupport = lib.mkDefault true;
      pinentryPackage = pkgs.pinentry-qt;
    };
  };
}
