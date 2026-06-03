{ config, lib, ... }:

{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  system.autoUpgrade = lib.mkIf (builtins.elem config.networking.hostName [
    "liltig"
    "nuc"
  ]) {
    enable = true;
    flake = "/home/cvandesande/nixos-config#${config.networking.hostName}";
    flags = [
      "--update-input"
      "nixpkgs"
      "--update-input"
      "nixpkgs-unstable"
    ];
    dates = "daily";
    randomizedDelaySec = "45min";
    allowReboot = false;
  };
}
