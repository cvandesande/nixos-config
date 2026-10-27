{ inputs, ... }:

{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.lanzaboote.nixosModules.lanzaboote

    ../base
    ../profiles/applications.nix
    ../profiles/desktop.nix
    ../profiles/dev-toolchain.nix
    ../profiles/secure-boot-luks.nix
    (import ../profiles/unfree.nix).devTools
    (import ../profiles/unfree.nix).desktop
    ../profiles/virtualisation-host.nix
    ../profiles/workstation.nix
  ];
}
