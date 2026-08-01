{ ... }:

{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  # system.autoUpgrade runs daily, so collect the superseded closures on a
  # schedule rather than relying on a manual nix-collect-garbage.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    randomizedDelaySec = "45min";
    options = "--delete-older-than 7d";
  };

  system.stateVersion = "26.05";

  time.timeZone = "Europe/Dublin";
}
