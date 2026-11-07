{ inputs, pkgs, ... }:

let
  lib = inputs.nixpkgs.lib;
  # NPU models served beside Flash, plus the guard's mode; one attrset so the
  # llm-npu-fetch alias below cannot drift from the container.
  npuEnv = {
    HALOGEN_NPU_MODELS = "halogen-spotter-0.6b,decider-4b,flux2-klein-4b";
    HALOGEN_AGENT_GUARD = "watch";
  };
  npuEnvArgs = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-e ${k}=${v}") npuEnv);

  # Interfaces allowed to reach halogen (:8731) and strixDash (:8787). Neither has auth,
  # so this names this box's NICs instead of the `en+`/`wl+` wildcards: those admitted any
  # interface named en*, which includes a USB dock on an untrusted network and any tunnel
  # that names itself enp*. Unlisted names are refused, so new hardware means adding its
  # name here (fail closed). The USB dongle's name is <controller PCI function> plus its
  # USB topology (`enp196s0f3u1u2`), so it is matched as a prefix: that survives a replug
  # to another port on the same controller, but a port wired to a different controller
  # renames it (`enp<other>s0f3u…`) and needs a new entry. Container bridges, veths and
  # tunnels stay refused by omission.
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
    ../../modules/roles/workstation.nix
    # by-path (PCI slot) rather than by-id: a by-id name is the drive's serial
    # (vendor OUI + unit number) and this repository is public. Slot names are
    # stable for a given bay, and Disko is the only consumer — the running system
    # mounts /dev/disk/by-partlabel/disk-main-* instead. Re-run Disko after a drive
    # move with the new path.
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

  # halogen's NPU needs the fabric clock pinned or it corrupts results and can hang the host
  # (ROCm/TheRock#8709). Row 7 = 2000 MHz, fclk only; keyed on the GPU's PCI function.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="drm", KERNELS=="0000:c2:00.0", ATTR{device/power_dpm_force_performance_level}="manual", ATTR{device/pp_dpm_fclk}="7"
  '';

  # Rootless podman, still as a system unit: linger provides /run/user/1000, and a static
  # uid is what makes the unit's RequiresMountsFor=/run/user/<uid>/containers resolve.
  users.users.cvandesande = {
    uid = 1000;
    linger = true;
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers.halogen = {
      image = "ghcr.io/peonist-ai/halogen-flash-server:latest";
      pull = "always";
      autoStart = false;
      podman.user = "cvandesande";
      ports = [ "8731:8731" ]; # all addresses; the firewall rules below limit it to the LAN NIC
      volumes = [ "/home/cvandesande/models/halogen-qwen3.8-flash-next:/models:ro" ];
      environment = npuEnv // {
        HALOGEN_TEMPERATURE = "1.0";
        HALOGEN_TOP_P = "0.95";
        HALOGEN_TOP_K = "20";
        HALOGEN_FORK = "1";
        HALOGEN_FORK_MAP = "claude-code";
        HALOGEN_CACHE_BRANCHES = "3";
        HALOGEN_KV8 = "1";
        HALOGEN_KV_POOL_POSITIONS = "925184";
        # Accept image content: loads the 857 MB vision tower that sits beside the
        # checkpoint. Unset, an image is a 400 and text behaviour is bit-identical.
        HALOGEN_VISION_TOWER = "1";
      };
      extraOptions = [
        "--device=/dev/kfd"
        "--device=/dev/dri"
        "--device=/dev/accel/accel0" # the NPU
        "--ipc=host" # ROCm needs it
        # No `--ulimit=memlock` (see LimitMEMLOCK below) and no seccomp option, so podman's
        # default profile applies -- it costs only perf_event_open and ptrace here.
      ];
    };
  };

  # Inherited by the container, unlike `--ulimit=memlock=-1:-1`, which would pin -1 in the
  # OCI spec for `podman exec` to fail re-applying from an 8 MB-capped shell (crun EPERM).
  systemd.services.podman-halogen.serviceConfig.LimitMEMLOCK = "infinity";

  # Rootless pasta binds :8731 as an ordinary host socket, so INPUT gates it, v4 and v6:
  # no DOCKER-USER hook to maintain any more.
  networking.firewall.interfaces = lib.genAttrs lanIfaces (_: {
    allowedTCPPorts = [ 8731 ];
  });

  # Nothing prunes rootless storage for you, so `pull = "always"` would pile up each
  # superseded :latest copy. Dangling images only: named images and volumes must survive.
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

  environment.shellAliases = {
    llm-start = "systemctl start podman-halogen";
    llm-stop = "systemctl stop podman-halogen";
    llm-status = "systemctl is-active podman-halogen";
    llm-update = "podman pull ghcr.io/peonist-ai/halogen-flash-server:latest";
    # One-off fetch of the NPU models: needs a writable mount (runtime is :ro), the clock
    # pinned, and llm-stop first. Ctrl-C once the files land. Shares npuEnv with the unit.
    # Rootless now, so what lands in /models is owned by cvandesande instead of root.
    llm-npu-fetch = "podman run --rm -v /home/cvandesande/models/halogen-qwen3.8-flash-next:/models -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next ${npuEnvArgs} --device=/dev/kfd --device=/dev/dri --device=/dev/accel/accel0 --ipc=host ghcr.io/peonist-ai/halogen-flash-server:latest";
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
