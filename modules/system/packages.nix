{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Desktop applications
    firefox
    onlyoffice-desktopeditors
    keepassxc
    nextcloud-client

    # Development and CLI tools
    git
    htop
    nodejs
    vim
    wget
    curl
    bubblewrap

    # Filesystem, encryption, and install support
    btrfs-progs
    compsize
    cryptsetup
  ];
}
