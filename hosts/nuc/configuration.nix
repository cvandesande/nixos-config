{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./hardware.nix

    ../../modules/base/nix-settings.nix
    ../../modules/base/remote-access.nix
    ../../modules/base/users.nix
    ../../modules/profiles/applications.nix
    ../../modules/profiles/desktop.nix
    ../../modules/profiles/secure-boot-luks.nix
    ../../modules/profiles/workstation.nix
    ../../modules/profiles/virtualisation-host.nix
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
