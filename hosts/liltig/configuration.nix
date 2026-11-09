{ inputs, pkgs, ... }:

let
  # None of halogen (:8731), strixDash (:8787) or Open WebUI (:8788) has a network gate, so these NICs are the gate.
  # Named NICs, not `en+`/`wl+` wildcards, and anything unlisted is refused; the trailing `+` is a prefix, so the USB dongle survives a replug.
  lanIfaces = [
    "enp191s0" # onboard ethernet
    "enp196s0+" # USB-C ethernet dongle; trailing `+` is iptables prefix matching
    "wlp192s0" # wifi
  ];
in
{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
    ./claude-router.nix
    (import ./strixdash.nix { inherit lanIfaces; })
    (import ./halogen.nix { inherit lanIfaces; })
    (import ./openwebui.nix { inherit lanIfaces; })
    ../../modules/roles/workstation.nix
    # by-path (PCI slot), not by-id: by-id is the drive's serial and this repo is public. Disko is the only consumer -- re-run it after moving a drive.
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-path/pci-0000:c1:00.0-nvme-1";
      swapSize = "32G";
    })
  ];

  networking.hostName = "liltig";
  networking.hostId = "534d981c";

  time.timeZone = "Europe/Dublin";
  system.stateVersion = "26.05";

  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false; # UsePAM defeats this
  };

  workstation.zfs.enable = false;

  services.tuned = {
    enable = true;
    ppdSupport = false;
    recommend.accelerator-performance = { };
  };

  systemd.services.tuned-ppd.unitConfig.ConditionPathExists = "/etc/tuned/ppd.conf";

  # Pin the fabric clock (row 7 = 2000 MHz) or halogen's NPU corrupts results and can hang the host (ROCm/TheRock#8709); keyed on the GPU's PCI function.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="drm", KERNELS=="0000:c2:00.0", ATTR{device/power_dpm_force_performance_level}="manual", ATTR{device/pp_dpm_fclk}="7"
  '';

  # Rootless podman, still a system unit: linger provides /run/user/1000 and the static uid resolves RequiresMountsFor=/run/user/<uid>/containers.
  users.users.cvandesande = {
    uid = 1000;
    linger = true;
  };

  # Nothing prunes rootless storage, so pull = "always" piles up each superseded :latest; dangling images only, named images and volumes survive.
  systemd.user.services.podman-dangling-prune = {
    description = "Remove dangling container images";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.podman}/bin/podman image prune -f";
    };
  };
  systemd.user.timers.podman-dangling-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      RandomizedDelaySec = "4h";
      Persistent = true;
    };
  };

  fileSystems."/home/cvandesande/mnt/whiterock" = {
    device = "whiterock:/zfspool/Downloads";
    fsType = "nfs4";
    options = [
      "defaults"
      "noauto"
      "noatime"
      "users"
      "bg"
      "x-systemd.mkdir"
    ];
  };
}
