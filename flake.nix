{
  description = "NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, lanzaboote, ... }:
    let
      system = "x86_64-linux";
    in {
      nixosConfigurations = {
        liltig = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            disko.nixosModules.disko
            ./hosts/liltig/disk-config.nix
            ./hosts/liltig/configuration.nix
          ];
        };

        nuc = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            disko.nixosModules.disko
            lanzaboote.nixosModules.lanzaboote
            ./hosts/nuc/disk-config.nix
            ./hosts/nuc/configuration.nix
          ];
        };
      };
    };
}
