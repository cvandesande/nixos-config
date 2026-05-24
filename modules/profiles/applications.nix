{ lib, pkgs, ... }:

{
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "obsidian"
    ];

  environment.systemPackages = with pkgs; [
    # Desktop applications
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

    # KDE applications
    kdePackages.isoimagewriter
    kdePackages.partitionmanager
    vlc
    hardinfo2
    nil
    nixd

    # Development and CLI tools
    htop
    nodejs
    bubblewrap
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
    libfido2
    pinentry-qt
    yubikey-manager
    yubikey-personalization
  ];

  programs = {
    firefox.enable = true;
    git.enable = true;
    thunderbird.enable = true;
    vim.enable = true;
    virt-manager.enable = true;

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
