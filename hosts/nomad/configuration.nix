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
    ./openvino.nix
    ../../modules/roles/workstation.nix
    # by-path (PCI slot) rather than by-id: a by-id name is the drive's serial
    # (vendor OUI + unit number) and this repository is public. Slot names are
    # stable for a given bay, and Disko is the only consumer — the running system
    # mounts /dev/disk/by-partlabel/disk-main-* instead.
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-path/pci-0000:01:00.0-nvme-1";
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

  # Speaker correction: see INSTALL.md section 10.
  environment.systemPackages = [ pkgs.easyeffects ];

  # Run as a user service rather than XDG autostart: EasyEffects aborts whenever
  # PipeWire disconnects (e.g. pipewire restarted by `nixos-rebuild switch`), and
  # XDG autostart units are never restarted.
  systemd.user.services.easyeffects = {
    description = "Easy Effects";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [
      "graphical-session.target"
      "pipewire.service"
      "wireplumber.service"
    ];
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

  # KDE writes the charge limit once and never re-applies it (KDE#450551) while the
  # EC resets it to 100% at boot, so UPower owns it: it re-applies CHARGE_LIMIT.
  # "_" skips the start threshold, which this battery does not expose.
  services.udev.extraHwdb = ''
    battery:*:FRANEDA:dmi:*
     CHARGE_LIMIT=_,85
  '';

  # UPower only writes the limit while the threshold is enabled (state lives in
  # /var/lib/upower, so it is re-asserted here to stay declarative).
  systemd.services.upower-charge-limit = {
    description = "Enable the UPower battery charge limit";
    after = [ "upower.service" ];
    wants = [ "upower.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      for attempt in $(seq 30); do
        ok=1
        for bat in /sys/class/power_supply/BAT*; do
          dev=/org/freedesktop/UPower/devices/battery_''${bat##*/}
          ${pkgs.systemd}/bin/busctl --system call org.freedesktop.UPower "$dev" \
            org.freedesktop.UPower.Device EnableChargeThreshold b true || ok=0
        done
        [ "$ok" = 1 ] && exit 0
        sleep 1
      done
      exit 1
    '';
  };
}
