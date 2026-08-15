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
    ../profiles/virtualisation-host.nix
    ../profiles/workstation.nix
  ];
}
