{
  description = "NixOS configuration for Framework Desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }:
    let
      system = "x86_64-linux";
    in {
      nixosConfigurations.framework-desktop = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          ./hosts/framework-desktop/disk-config.nix
          ./hosts/framework-desktop/configuration.nix
        ];
      };
    };
}
