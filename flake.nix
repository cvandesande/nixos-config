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
            pkgsUnstable = import inputs.nixpkgs-unstable {
              inherit system;
              config.allowUnfreePredicate =
                pkg:
                builtins.elem (nixpkgs.lib.getName pkg) [
                  "discord"
                  "obsidian"
                  "stremio-linux-shell"
                  "zoom"
                ];
            };
          };
        };

      baseModules = [
        ./modules/base/nix-settings.nix
        ./modules/base/remote-access.nix
        ./modules/base/users.nix
      ];

      devModules = [
        ./modules/profiles/dev-toolchain.nix
      ];

      desktopModules = [
        ./modules/profiles/applications.nix
        ./modules/profiles/desktop.nix
      ];

      workstationModules = [
        ./modules/profiles/secure-boot-luks.nix
        ./modules/profiles/virtualisation-host.nix
        ./modules/profiles/workstation.nix
      ];

      mkWorkstation =
        modules:
        mkNixos "x86_64-linux" (
          [
            disko.nixosModules.disko
            lanzaboote.nixosModules.lanzaboote
          ]
          ++ baseModules
          ++ devModules
          ++ desktopModules
          ++ workstationModules
          ++ modules
        );

      mkVm =
        system:
        mkNixos system (
          [ disko.nixosModules.disko ] ++ baseModules ++ devModules ++ [ ./hosts/nix-vm/configuration.nix ]
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
