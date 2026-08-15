{ inputs, ... }:

{
  imports = [
    inputs.disko.nixosModules.disko

    ../base
    ../profiles/dev-toolchain.nix
  ];
}
