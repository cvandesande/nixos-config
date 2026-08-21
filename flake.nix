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
      ...
    }:
    let
      mkNixos =
        system: module:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ module ];
          specialArgs = {
            inherit inputs;
            pkgsUnstable = import inputs.nixpkgs-unstable {
              inherit system;
              config.allowUnfreePredicate =
                pkg:
                builtins.elem (nixpkgs.lib.getName pkg) [
                  "discord"
                  "obsidian"
                  "zoom"
                ];
            };
          };
        };

    in
    {
      nixosConfigurations = {
        liltig = mkNixos "x86_64-linux" ./hosts/liltig/configuration.nix;
        nuc = mkNixos "x86_64-linux" ./hosts/nuc/configuration.nix;
        nix-vm-x86_64 = mkNixos "x86_64-linux" ./hosts/nix-vm/configuration.nix;
        nix-vm-aarch64 = mkNixos "aarch64-linux" ./hosts/nix-vm/configuration.nix;
      };
    };
}
