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

  services.fstrim.enable = true;

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  services.openssh.enable = lib.mkDefault true;

  users.users.chris = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };

  networking.networkmanager.enable = true;

  environment.systemPackages = with pkgs; [
    git
    vim
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
