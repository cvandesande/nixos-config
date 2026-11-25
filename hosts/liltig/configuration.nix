{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  # Neither halogen (:8731) nor Open WebUI (:8788) has a network gate, so these NICs are the gate.
  # Named NICs, not `en+`/`wl+` wildcards, and anything unlisted is refused; the trailing `+` is a
  # prefix, so the USB dongle survives a replug.
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
    (import ./halogen.nix { inherit lanIfaces; })
    (import ./openwebui.nix { inherit lanIfaces; })
    ./stt-proxy.nix
    ../../modules/roles/workstation.nix
    # by-path (PCI slot), not by-id: by-id is the drive's serial and this repo is public. Disko
    # is the only consumer -- re-run it after moving a drive.
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

  # Pin the fabric clock (row 7 = 2000 MHz) or halogen's NPU corrupts results and can hang the
  # host (ROCm/TheRock#8709); keyed on the GPU's PCI function.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="drm", KERNELS=="0000:c2:00.0", ATTR{device/power_dpm_force_performance_level}="manual", ATTR{device/pp_dpm_fclk}="7"
  '';

  # btop is built against rocm-smi here, so the Radeon iGPU gets a panel; rocm-smi cannot talk to
  # the Intel iGPUs in nomad and nuc, so they keep the plain build the profile installs.
  devToolchain.btop.package = pkgs.btop-rocm;

  # Rootless podman, still a system unit: linger provides /run/user/1000 and the static uid
  # resolves RequiresMountsFor=/run/user/<uid>/containers.
  users.users.cvandesande = {
    uid = 1000;
    linger = true;
  };

  # Nothing prunes rootless storage, so pull = "always" piles up each superseded :latest; dangling
  # images only, named images and volumes survive.
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

  # Talos, pkgs and extensions build only through BuildKit, so /bin/docker must be an engine.
  virtualisation = {
    # Asserts against docker.enable in the podman module; mkForce beats the profile's true.
    podman.dockerCompat = lib.mkForce false;

    docker = {
      enable = true;
      enableOnBoot = false; # socket-activated: starts when a build opens /run/docker.sock
      storageDriver = "overlay2"; # docker's btrfs driver is deprecated upstream (86423b9)
    };
  };

  # docker.socket is 0660 root:docker, so without the group every build step needs sudo.
  users.groups.docker.members = [ "cvandesande" ];

  # No @docker subvolume since 86423b9, so +C per inode is the only NOCOW this store can get.
  systemd.tmpfiles.rules = [
    "d /var/lib/docker 0711 root root -"
    "h /var/lib/docker - - - - +C"
  ];

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
