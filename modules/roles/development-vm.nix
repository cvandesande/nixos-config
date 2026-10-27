{ inputs, ... }:

{
  imports = [
    inputs.disko.nixosModules.disko

    ../base
    ../profiles/dev-toolchain.nix
    (import ../profiles/unfree.nix).devTools
  ];
}
