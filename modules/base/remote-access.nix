{ lib, pkgs, ... }:

{
  services.openssh.enable = lib.mkDefault true;

  # SSH from Ghostty fails without xterm-ghostty in the system terminfo database.
  environment.systemPackages = [ pkgs.ghostty.terminfo ];
}
