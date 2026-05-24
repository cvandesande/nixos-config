{ ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../../modules/base/nix-settings.nix
    ../../modules/base/remote-access.nix
    ../../modules/base/users.nix
    ../../modules/profiles/dev-toolchain.nix
    ../../modules/profiles/headless.nix
    ../../modules/profiles/vm-boot.nix
  ];

  networking.hostName = "nix-vm";

  time.timeZone = "Europe/Dublin";

  system.stateVersion = "25.11";
}
