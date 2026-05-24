{ lib, pkgs, ... }:

{
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "obsidian"
    ];

  environment.systemPackages = with pkgs; [
    # Desktop applications
    firefox
    thunderbird
    onlyoffice-desktopeditors
    keepassxc
    nextcloud-client
    obsidian
    gajim
    epsonscan2
    fastfetch
    talosctl
    kubectl
    kubernetes-helm
    unzip

    # Hardware tools
    pciutils
    libva-utils
    vulkan-tools
    virt-manager

    # KDE
    kdePackages.isoimagewriter
    kdePackages.partitionmanager
    vlc
    hardinfo2
    nil
    nixd

    # Development and CLI tools
    git
    htop
    nodejs
    bubblewrap
    vim
    curl
    zed-editor
    sops
    gh
    ripgrep

    # Filesystem, encryption, and install support
    btrfs-progs
    compsize
    cryptsetup
    sbctl
    tpm2-tools

    # YubiKey, FIDO2, and GPG/SSH-agent support
    gnupg
    libfido2
    pinentry-qt
    yubikey-manager
    yubikey-personalization
  ];
}
