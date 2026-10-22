{
  config,
  lib,
  ...
}:

{
  imports = [
    ./claude-router.nix
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

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  workstation.zfs.enable = false;

  services.tuned = {
    enable = true;
    ppdSupport = false;
    recommend.accelerator-performance = { };
  };

  systemd.services.tuned-ppd.unitConfig.ConditionPathExists = "/etc/tuned/ppd.conf";

  virtualisation.oci-containers = {
    backend = "docker";
    containers.halogen = {
      image = "ghcr.io/peonist-ai/halogen-flash-server:latest";
      pull = "always";
      autoStart = false;
      ports = [ "127.0.0.1:8731:8731" ];
      volumes = [ "/home/cvandesande/models/halogen-qwen3.8-flash-next:/models:ro" ];
      environment = {
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
