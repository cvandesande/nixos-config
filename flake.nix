{
  description = "NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Release binaries (packer and rtk are unfree, see modules/profiles/unfree.nix;
    # spotifast is not). rtk uses a releases/latest URL, so `nix flake update`
    # picks up new releases. packer and spotifast put the version in the file
    # name, so they are bumped by hand; the lock file re-pins the hashes:
    #   sed -i 's/v0.16.0/vX.Y.Z/g' flake.nix && \
    #     nix flake update spotifast-x86_64-linux spotifast-aarch64-linux
    #   sed -i 's/1.16.2/X.Y.Z/g' flake.nix && \
    #     nix flake update packer-x86_64-linux packer-aarch64-linux
    packer-x86_64-linux = {
      url = "file+https://releases.hashicorp.com/packer/1.16.2/packer_1.16.2_linux_amd64.zip";
      flake = false;
    };
    packer-aarch64-linux = {
      url = "file+https://releases.hashicorp.com/packer/1.16.2/packer_1.16.2_linux_arm64.zip";
      flake = false;
    };
    rtk-x86_64-linux = {
      url = "file+https://github.com/rtk-ai/rtk/releases/latest/download/rtk-oss-x86_64-unknown-linux-musl.tar.gz";
      flake = false;
    };
    rtk-aarch64-linux = {
      url = "file+https://github.com/rtk-ai/rtk/releases/latest/download/rtk-oss-aarch64-unknown-linux-gnu.tar.gz";
      flake = false;
    };
    spotifast-x86_64-linux = {
      url = "file+https://github.com/crmne/spotifast/releases/download/v0.16.0/spotifast-v0.16.0-x86_64-unknown-linux-gnu.tar.gz";
      flake = false;
    };
    spotifast-aarch64-linux = {
      url = "file+https://github.com/crmne/spotifast/releases/download/v0.16.0/spotifast-v0.16.0-aarch64-unknown-linux-gnu.tar.gz";
      flake = false;
    };

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
                builtins.elem (nixpkgs.lib.getName pkg) (import ./modules/profiles/unfree.nix).names;
            };
          };
        };

    in
    {
      nixosConfigurations = {
        liltig = mkNixos "x86_64-linux" ./hosts/liltig/configuration.nix;
        nuc = mkNixos "x86_64-linux" ./hosts/nuc/configuration.nix;
        nomad = mkNixos "x86_64-linux" ./hosts/nomad/configuration.nix;
        nix-vm-x86_64 = mkNixos "x86_64-linux" ./hosts/nix-vm/configuration.nix;
        nix-vm-aarch64 = mkNixos "aarch64-linux" ./hosts/nix-vm/configuration.nix;
      };
    };
}
