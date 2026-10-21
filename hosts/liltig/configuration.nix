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

  # Key-only SSH. KbdInteractiveAuthentication has to go too: with UsePAM it
  # accepts the account password and would bypass PasswordAuthentication.
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # No local ZFS pools (LUKS+btrfs storage), opt out of global workstation ZFS.
  workstation.zfs.enable = false;

  # Prioritize inference throughput and disable higher-latency CPU idle states.
  # ppdSupport = false is load-bearing: with it true, tuned's power-profiles
  # compatibility layer applies its own profile and overrides recommend.
  services.tuned = {
    enable = true;
    ppdSupport = false;
    recommend.accelerator-performance = { };
  };

  # The tuned module puts the package in systemd.packages, so upstream
  # tuned-ppd.service is linked and started through its own [Install] section
  # even though ppdSupport is false. It then exits 1 because /etc/tuned/ppd.conf
  # is only generated when ppdSupport is true. Skip it instead of failing.
  systemd.services.tuned-ppd.unitConfig.ConditionPathExists = "/etc/tuned/ppd.conf";

  # Strix Halo local LLM: Qwen3.8-Flash-Next served by halogen-flash-server, a
  # closed-source ROCm engine built for gfx1151 only. It speaks the Anthropic
  # Messages API (/v1/messages), and claude-router sends local requests to it.
  # Weights (v2 checkpoint, n-gram table, MTP head, tokenizer) come from
  #   hf download peonist-ai/halogen-qwen3.8-flash-next --local-dir ~/models/halogen-qwen3.8-flash-next
  # HALOGEN_DOWNLOAD is unset, so the container makes no outbound connection
  # and /models stays read-only. Shipped defaults otherwise.
  virtualisation.oci-containers = {
    backend = "docker";
    containers.halogen = {
      image = "ghcr.io/peonist-ai/halogen-flash-server:0.18.13@sha256:2e98dc53ed4a43b5600b11a80852eedfa573f4ffc3f10c64da01245f2a3217fc";
      autoStart = false;
      ports = [ "127.0.0.1:8731:8731" ];
      volumes = [ "/home/cvandesande/models/halogen-qwen3.8-flash-next:/models:ro" ];
      # Claude Code sends no sampling fields, and halogen decodes such requests
      # greedy, which can loop inside the think block at long context. Default
      # to the model card's thinking settings. A request that sends its own
      # values still wins.
      environment = {
        HALOGEN_TEMPERATURE = "1.0";
        HALOGEN_TOP_P = "0.95";
        HALOGEN_TOP_K = "20";
        # Keep each Claude Code thread's state (main conversation and every
        # subagent) so its next request starts from it. Needs no client
        # setting; claude-router passes the session headers through.
        HALOGEN_FORK = "1";
        HALOGEN_FORK_MAP = "claude-code";
        # Keep resume points for a parent plus two children, so a subagent's
        # save does not replace the parent's (about 0.8 GiB more host RAM).
        HALOGEN_CACHE_BRANCHES = "3";
        # Store the attention cache in 8 bits and spend the saved memory on a
        # larger pool: 925,184 positions fit where 524,288 did, so more
        # 160k-token requests and kept states fit at once. Costs about 2%
        # decode speed at 32k. Do not combine with HALOGEN_COMPOSABLE_CONTEXT.
        HALOGEN_KV8 = "1";
        HALOGEN_KV_POOL_POSITIONS = "925184";
      };
      # ROCm needs /dev/kfd as well as /dev/dri (both mode 0666, so no
      # group-add). The GPU runtime dies at startup without --ipc=host.
      extraOptions = [
        "--device=/dev/kfd"
        "--device=/dev/dri"
        "--ipc=host"
        "--ulimit=memlock=-1:-1"
      ];
    };
  };

  # system.autoUpgrade switches live, and a docker.service restart takes the LLM
  # container (and any in-flight generation) down with it. Keep the running
  # daemon across switches; the new docker takes effect at the next reboot.
  systemd.services.docker.restartIfChanged = false;

  # llm-* control the backend claude-router sends local requests to (halogen).
  environment.shellAliases = {
    llm-start = "systemctl start docker-halogen";
    llm-stop = "systemctl stop docker-halogen";
    llm-status = "systemctl is-active docker-halogen";
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
