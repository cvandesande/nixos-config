{
  description = "NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@
    {
      nixpkgs,
      disko,
      lanzaboote,
      ...
    }:
    let
      mkNixos =
        system: modules:
        nixpkgs.lib.nixosSystem {
          inherit system modules;
          specialArgs = {
            inherit inputs;
          };
        };

      mkWorkstation =
        modules:
        mkNixos "x86_64-linux" (
          [
            disko.nixosModules.disko
            lanzaboote.nixosModules.lanzaboote
          ]
          ++ modules
        );

      mkVm =
        system:
        mkNixos system [
          disko.nixosModules.disko
          ./hosts/nix-vm/disk-config.nix
          ./hosts/nix-vm/configuration.nix
        ];
    in
    {
      nixosConfigurations = {
        liltig = mkWorkstation [
          ./hosts/liltig/disk-config.nix
          ./hosts/liltig/configuration.nix
        ];

        nuc = mkWorkstation [
          ./hosts/nuc/disk-config.nix
          ./hosts/nuc/configuration.nix
        ];

        nix-vm-x86_64 = mkVm "x86_64-linux";
        nix-vm-aarch64 = mkVm "aarch64-linux";
      };
    };
}
