{
  lib,
  pkgs,
  pkgsUnstable,
  inputs,
  ...
}:

{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "google-chrome"
    "discord"
    "steam"
    "steam-unwrapped"
  ];

  environment = {
    systemPackages = with pkgs; [
      # Desktop applications
      google-chrome
      chromium
      discord
      epsonscan2
      gajim
      pkgsUnstable.keepassxc
      pkgsUnstable.nextcloud-client
      pkgsUnstable.obsidian
      onlyoffice-desktopeditors
      signal-desktop
      (callPackage ../../pkgs/spotifast.nix { src = inputs."spotifast-${pkgs.stdenv.hostPlatform.system}"; })

      # Hardware tools
      amdgpu_top
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
      ncdu
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
      SSH_ASKPASS_REQUIRE = "force";
    };

    # Chrome policy: disable AI Mode (https://chromeenterprise.google/policies/ai-mode-settings/).
    etc."opt/chrome/policies/managed/ai-mode.json".text = builtins.toJSON {
      AIModeSettings = 1;
    };
  };

  programs = {
    firefox.enable = true;
    kdeconnect.enable = true;
    thunderbird.enable = true;
    steam.enable = true;
    virt-manager.enable = true;
    zoom-us = {
      enable = true;
      package = pkgsUnstable.zoom-us;
    };

    # Lets unpackaged static binaries find their interpreter.
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

    ssh = {
      startAgent = lib.mkDefault true;
      enableAskPassword = true;
      askPassword = "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";
    };

    gnupg.agent = {
      enable = true;
      enableSSHSupport = lib.mkDefault false;
      pinentryPackage = pkgs.pinentry-qt;
    };

  };
}
