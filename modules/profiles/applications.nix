{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfreePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "discord"
        "obsidian"
        "stremio-linux-shell"
        "zoom"
      ];
  };

  ha-mcp = pkgs.writeShellApplication {
    name = "ha-mcp";
    runtimeInputs = [
      pkgs.python313
      pkgs.uv
    ];
    text = ''
      if [[ -f /var/lib/ha-mcp/env ]]; then
        set -a
        # shellcheck disable=SC1091
        source /var/lib/ha-mcp/env
        set +a
      fi

      exec uvx --python ${pkgs.python313}/bin/python3.13 ha-mcp@latest "$@"
    '';
  };
in
{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ ];

  environment.systemPackages = with pkgs; [
    # Desktop applications
    unstable.discord
    epsonscan2
    fastfetch
    gajim
    unstable.keepassxc
    unstable.nextcloud-client
    unstable.obsidian
    onlyoffice-desktopeditors
    signal-desktop
    unstable.stremio-linux-shell
    unzip

    # Hardware tools
    libva-utils
    pciutils
    vulkan-tools

    # KDE specific
    papirus-icon-theme
    kdePackages.isoimagewriter
    kdePackages.partitionmanager
    hardinfo2
    vlc

    # Development and CLI tools
    htop
    unstable.nodejs
    bubblewrap
    cosign
    file
    yq
    jq
    curl
    tree
    nil
    nixd
    nix-index
    nixfmt
    statix
    deadnix
    dnsutils
    socat
    unstable.zed-editor
    unstable.sops
    unstable.gh
    unstable.talosctl
    unstable.kubectl
    unstable.kubectl-cnpg
    unstable.kubernetes-helm
    ha-mcp

    # Python and packages
    (python313.withPackages (ps: with ps; [
      pyyaml
    ]))

    # Filesystem, encryption, and install support
    btrfs-progs
    compsize
    cryptsetup
    sbctl
    tpm2-tools

    # YubiKey, FIDO2, and GPG/SSH-agent support
    libfido2
    pinentry-qt
    yubikey-manager
    yubikey-personalization
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/ha-mcp 0700 root root -"
  ];

  programs = {
    firefox = {
      enable = true;
      package = unstable.firefox;
      preferences = {
        "widget.use-xdg-desktop-portal.file-picker" = 1;
      };
    };
    git.enable = true;
    thunderbird.enable = true;
    vim.enable = true;
    virt-manager.enable = true;
    zoom-us = {
      enable = true;
      package = unstable.zoom-us;
    };

    # Zed downloads language servers such as rust-analyzer as generic Linux
    # binaries, which expect the standard dynamic loader path to exist.
    nix-ld = {
      enable = true;
      libraries = with pkgs; [
        stdenv.cc.cc
      ];
    };

    dconf.profiles.user.databases = [
      {
        locks = [
          "/org/virt-manager/virt-manager/connections/autoconnect"
          "/org/virt-manager/virt-manager/connections/uris"
        ];
        settings."org/virt-manager/virt-manager/connections" = {
          autoconnect = [ "qemu:///system" ];
          uris = [ "qemu:///system" ];
        };
      }
    ];

    # Use gpg-agent as the default SSH agent so SSH keys can live on a YubiKey.
    # Hosts can override this when they need a different agent backend.
    ssh.startAgent = lib.mkDefault false;

    gnupg.agent = {
      enable = true;
      enableSSHSupport = lib.mkDefault true;
      pinentryPackage = pkgs.pinentry-qt;
    };
  };
}
