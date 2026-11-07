# All unfree software in one place for review. Nothing here is compiled: nixpkgs repackages vendor binaries, packer and rtk come from the flake inputs.
# names is the allow-list (also used for pkgsUnstable); devTools adds packer and rtk; desktop adds the graphical apps on top of devTools.
let
  names = [
    "discord"
    "google-chrome"
    "obsidian"
    "packer"
    "rtk"
    "steam"
    "steam-unwrapped"
    "zoom"
  ];
in
{
  inherit names;

  devTools =
    {
      inputs,
      lib,
      pkgs,
      ...
    }:

    let
      system = pkgs.stdenv.hostPlatform.system;
    in
    {
      nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) names;

      environment.systemPackages = [
        (pkgs.callPackage ../../pkgs/packer.nix { src = inputs."packer-${system}"; })
        (pkgs.callPackage ../../pkgs/rtk.nix { src = inputs."rtk-${system}"; })
      ];
    };

  desktop =
    { pkgs, pkgsUnstable, ... }:

    {
      environment = {
        systemPackages = [
          pkgs.google-chrome
          pkgs.discord
          pkgsUnstable.obsidian
        ];

        # Chrome policy: disable AI Mode (https://chromeenterprise.google/policies/ai-mode-settings/).
        etc."opt/chrome/policies/managed/ai-mode.json".text = builtins.toJSON {
          AIModeSettings = 1;
        };
      };

      programs = {
        steam.enable = true;
        zoom-us = {
          enable = true;
          package = pkgsUnstable.zoom-us;
        };
      };
    };
}
