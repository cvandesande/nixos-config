{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./hardware.nix

    ../../modules/system/applications.nix
    ../../modules/system/boot.nix
    ../../modules/system/hardware.nix
    ../../modules/system/nix-settings.nix
    ../../modules/system/services.nix
    ../../modules/system/users.nix
    ../../modules/system/virtualisation.nix
  ];

  networking.hostName = "nuc";

  time.timeZone = "Europe/Dublin";

  boot = {
    kernelPackages = pkgs.linuxPackages_xanmod_latest;

    # Work around this NUC firmware exposing the TPM2 CRB command buffer in a
    # region Linux otherwise treats as busy:
    # tpm_crb MSFT0101:00: error -EBUSY ... [mem 0xa2fff000-0xa2fff02f]
    kernelParams = [
      "memmap=0x1000%0xa2fff000+2"
    ];
  };

  programs = {
    # This NUC has only USB-A ports, so use OpenSSH's agent for KeePassXC
    # instead of gpg-agent's YubiKey-oriented SSH support.
    ssh.startAgent = true;
    gnupg.agent.enableSSHSupport = false;
  };

  # Change this only after reading the NixOS release notes for the release
  # used when the machine was first installed.
  system.stateVersion = "25.11";
}
