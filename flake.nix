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
    inputs@{
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

      commonModules = [
        ./modules/base/nix-settings.nix
        ./modules/base/remote-access.nix
        ./modules/base/users.nix
        ./modules/profiles/dev-toolchain.nix
        ./modules/profiles/unstable-kernel.nix
        ./modules/storage/zfs.nix
        {
          time.timeZone = "Europe/Dublin";
          system.stateVersion = "25.11";
        }
      ];

      workstationModules = [
        ./modules/profiles/applications.nix
        ./modules/profiles/desktop.nix
        ./modules/profiles/secure-boot-luks.nix
        ./modules/profiles/virtualisation-host.nix
        ./modules/profiles/workstation.nix
      ];

      vmModules = [
        ./modules/profiles/headless.nix
        ./modules/profiles/vm-boot.nix
      ];

      mkWorkstation =
        modules:
        mkNixos "x86_64-linux" (
          [
            disko.nixosModules.disko
            lanzaboote.nixosModules.lanzaboote
          ]
          ++ commonModules
          ++ workstationModules
          ++ modules
        );

      mkVm =
        system:
        mkNixos system (
          [ disko.nixosModules.disko ] ++ commonModules ++ vmModules ++ [ ./hosts/nix-vm/configuration.nix ]
        );
    in
    {
      nixosConfigurations = {
        liltig = mkWorkstation [
          ./hosts/liltig/configuration.nix
        ];

        nuc = mkWorkstation [
          ./hosts/nuc/configuration.nix
        ];

        nix-vm-x86_64 = mkVm "x86_64-linux";
        nix-vm-aarch64 = mkVm "aarch64-linux";
      };
    };
}
