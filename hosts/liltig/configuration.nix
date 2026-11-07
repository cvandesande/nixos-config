{ inputs, pkgs, ... }:

let
  lib = inputs.nixpkgs.lib;
  # NPU models served beside Flash, plus the guard's mode; one attrset so llm-npu-fetch below cannot drift.
  # qwen3-embedding-0.6b: Open WebUI's knowledge search, ~0.8 GiB locked; fetched with the image's huggingface_hub, not llm-npu-fetch (needs llm-stop).
  npuEnv = {
    HALOGEN_NPU_MODELS = "halogen-spotter-0.6b,decider-4b,flux2-klein-4b,qwen3-embedding-0.6b";
    HALOGEN_AGENT_GUARD = "watch";
  };
  npuEnvArgs = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-e ${k}=${v}") npuEnv);

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
        # Loads the 857 MB vision tower beside the checkpoint; unset, an image is a 400 and text behaviour is bit-identical.
        HALOGEN_VISION_TOWER = "1";
      };
      extraOptions = [
        "--device=/dev/kfd"
        "--device=/dev/dri"
        "--device=/dev/accel/accel0" # the NPU
        "--ipc=host" # ROCm needs it
        # No --ulimit=memlock (see LimitMEMLOCK below) and no seccomp option, so podman's default profile applies.
      ];
    };
  };

  # Inherited by the container, unlike --ulimit=memlock=-1:-1, which podman exec then fails to re-apply from an 8 MB-capped shell (crun EPERM).
  systemd.services.podman-halogen.serviceConfig.LimitMEMLOCK = "infinity";

  # Rootless pasta binds :8731 as an ordinary host socket, so INPUT gates it, v4 and v6 -- no DOCKER-USER hook to maintain.
  networking.firewall.interfaces = lib.genAttrs lanIfaces (_: {
    allowedTCPPorts = [ 8731 ];
  });

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

  environment.shellAliases = {
    llm-start = "systemctl start podman-halogen";
    llm-stop = "systemctl stop podman-halogen";
    llm-status = "systemctl is-active podman-halogen";
    llm-update = "podman pull ghcr.io/peonist-ai/halogen-flash-server:latest";
    # One-off NPU model fetch: needs a writable mount (runtime is :ro), the clock pinned, and llm-stop first; Ctrl-C once the files land.
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
