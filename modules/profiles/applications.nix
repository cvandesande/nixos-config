{
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:

{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ ];

  environment = {
    systemPackages = with pkgs; [
      # Desktop applications
      pkgsUnstable.discord
      epsonscan2
      gajim
      pkgsUnstable.keepassxc
      pkgsUnstable.nextcloud-client
      pkgsUnstable.obsidian
      onlyoffice-desktopeditors
      signal-desktop
      pkgsUnstable.stremio-linux-shell

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

      # Filesystem, encryption, and install support
      btrfs-progs
      compsize
      cryptsetup
      sbctl
      tpm2-tools

      # YubiKey, FIDO2, and GPG/SSH-agent support
      libfido2
      pinentry-qt
      kdePackages.ksshaskpass
      yubikey-manager
      yubikey-personalization
    ];

    sessionVariables = {
      SSH_ASKPASS = "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";
      SSH_ASKPASS_REQUIRE = "force";
    };
  };

  programs = {
    firefox.enable = true;
    thunderbird.enable = true;
    virt-manager.enable = true;
    zoom-us = {
      enable = true;
      package = pkgsUnstable.zoom-us;
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

    # SSH keys live on a YubiKey as FIDO2 credentials (sk-ssh-ed25519), not
    # GPG. Use OpenSSH's own agent so it's the only one offering identities;
    # gpg-agent's SSH support previously shadowed the FIDO2 key with the
    # YubiKey's OpenPGP auth subkey, which has touch confirmation disabled.
    ssh.startAgent = lib.mkDefault true;

    gnupg.agent = {
      enable = true;
      enableSSHSupport = lib.mkDefault false;
      pinentryPackage = pkgs.pinentry-qt;
    };
  };
}
