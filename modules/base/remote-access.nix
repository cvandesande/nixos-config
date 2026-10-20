{ lib, pkgs, ... }:

{
  services.openssh.enable = lib.mkDefault true;

  # Ghostty sets TERM=xterm-ghostty, which isn't in the stock terminfo
  # database. Without this, SSHing in from Ghostty fails with
  # "'xterm-ghostty': unknown terminal type."
  environment.systemPackages = [ pkgs.ghostty.terminfo ];
}
