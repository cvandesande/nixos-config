{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-intel-core-ultra-series3
    ../../modules/roles/workstation.nix
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4f03f482";
      swapSize = "16G";
    })
  ];

  networking.hostName = "nomad";
  networking.hostId = "58d246a9";

  time.timeZone = "Europe/Dublin";
  system.stateVersion = "26.05";

  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false; # UsePAM defeats this
  };

  boot.kernelModules = [ "kvm-intel" ];

  # Unused here; avoids the "supply vcc not found" probe message at boot.
  boot.blacklistedKernelModules = [ "spi_nor" ];

  # Speaker correction: see README section 10.
  environment.systemPackages = [ pkgs.easyeffects ];

  # Run as a user service rather than XDG autostart: EasyEffects aborts whenever
  # PipeWire disconnects (e.g. pipewire restarted by `nixos-rebuild switch`), and
  # XDG autostart units are never restarted.
  systemd.user.services.easyeffects = {
    description = "Easy Effects";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "pipewire.service" "wireplumber.service" ];
    wants = [ "pipewire.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.easyeffects}/bin/easyeffects --hide-window --service-mode";
      ExecStop = "${pkgs.easyeffects}/bin/easyeffects --quit";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  workstation.zfs.enable = false;

  # power-profiles-daemon doesn't react to AC changes: pick the profile from
  # the mains state at boot and whenever the charger is (un)plugged.
  systemd.services.power-profile-auto = {
    description = "Set power profile from AC state";
    after = [ "power-profiles-daemon.service" ];
    wants = [ "power-profiles-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      for ps in /sys/class/power_supply/*; do
        [ "$(cat "$ps/type")" = Mains ] || continue
        if [ "$(cat "$ps/online")" = 1 ]; then profile=balanced; else profile=power-saver; fi
        exec ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set "$profile"
      done
    '';
  };
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", ATTR{type}=="Mains", TAG+="systemd", ENV{SYSTEMD_WANTS}+="power-profile-auto.service"
  '';
}
