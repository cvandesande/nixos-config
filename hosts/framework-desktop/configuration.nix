{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "framework-desktop";

  time.timeZone = "Europe/Dublin";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Required for TPM2-based LUKS unlock later.
  # Keep password unlock working first; add TPM enrollment only after the base install boots.
  boot.initrd.systemd.enable = true;

  # Weekly SSD/NVMe TRIM. This is enabled by default in current NixOS, but kept
  # explicit here because the disk layout intentionally uses LUKS + Btrfs.
  services.fstrim.enable = true;

  # Monthly Btrfs scrub. Scrub verifies checksums and is independent from TRIM.
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };

  services.openssh.enable = lib.mkDefault true;

  users.users.chris = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };

  networking.networkmanager.enable = true;

  environment.systemPackages = with pkgs; [
    firefox
    onlyoffice-desktopeditors
    htop
    vim
    keepassxc
    nextcloud-client
    nodejs
    bubblewrap

    git
    wget
    curl
    btrfs-progs
    compsize
    cryptsetup
  ];

  # Change this only after reading the NixOS release notes for the release
  # used when the machine was first installed.
  system.stateVersion = "26.05";
}
