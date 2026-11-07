{ inputs, ... }:

let
  lib = inputs.nixpkgs.lib;
  # The guard's two NPU models and its mode, in one attrset so the fetch alias below
  # cannot drift from the container.
  npuEnv = {
    HALOGEN_NPU_MODELS = "halogen-spotter-0.6b,decider-4b";
    HALOGEN_AGENT_GUARD = "watch";
  };
  npuEnvArgs = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-e ${k}=${v}") npuEnv);
in
{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
    ./claude-router.nix
    ./strixdash.nix
    ../../modules/roles/workstation.nix
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4086d232";
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

  virtualisation.oci-containers = {
    backend = "docker";
    containers.halogen = {
      image = "ghcr.io/peonist-ai/halogen-flash-server:latest";
      pull = "always";
      autoStart = false;
      ports = [ "127.0.0.1:8731:8731" ];
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
      };
      extraOptions = [
        "--device=/dev/kfd"
        "--device=/dev/dri"
        "--device=/dev/accel/accel0" # the NPU
        "--ipc=host" # ROCm needs it
        "--ulimit=memlock=-1:-1"
      ];
    };
  };

  virtualisation.docker.autoPrune = {
    enable = true;
    dates = "weekly";
  };

  systemd.services.docker.restartIfChanged = false; # a restart kills the container

  environment.shellAliases = {
    llm-start = "systemctl start docker-halogen";
    llm-stop = "systemctl stop docker-halogen";
    llm-status = "systemctl is-active docker-halogen";
    llm-update = "docker pull ghcr.io/peonist-ai/halogen-flash-server:latest";
    # One-off fetch of the NPU models: needs a writable mount (runtime is :ro), the clock
    # pinned, and llm-stop first. Ctrl-C once the files land. Shares npuEnv with the unit.
    llm-npu-fetch = "docker run --rm -v /home/cvandesande/models/halogen-qwen3.8-flash-next:/models -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next ${npuEnvArgs} --device=/dev/kfd --device=/dev/dri --device=/dev/accel/accel0 --ipc=host --ulimit=memlock=-1:-1 ghcr.io/peonist-ai/halogen-flash-server:latest";
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
